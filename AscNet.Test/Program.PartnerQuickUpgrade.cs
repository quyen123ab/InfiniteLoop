using AscNet.Common.Database;
using AscNet.Common.MsgPack;
using AscNet.Common.Util;
using AscNet.GameServer.Handlers;
using AscNet.Table.V2.share.partner;
using AscNet.Table.V2.share.partner.leveluptemplate;
using MongoDB.Driver;

namespace AscNet.Test;

internal partial class Program
{
    private static void ValidatePartnerQuickUpgrade()
    {
        const long uid = 99_673;
        const int partnerId = 1;
        const int templateId = 16_090_000;
        const int smallExp = 30111;
        const int mediumExp = 30112;
        const int largeExp = 30113;
        const int unlistedExp = 30114;
        const int smallOverclock = 40200;
        const int largeOverclock = 40201;
        var originalPlayers = Player.collection;
        var originalCharacters = Character.collection;
        var originalInventory = Inventory.collection;
        var client = AscNet.Common.Common.db.Client;
        string databaseName = "ascnet_partner_quick_upgrade_" + Guid.NewGuid().ToString("N");
        var database = client.GetDatabase(databaseName);
        Player.collection = database.GetCollection<Player>("players");
        Character.collection = database.GetCollection<Character>("characters");
        Inventory.collection = database.GetCollection<Inventory>("inventory");
        try
        {
            var character = CreateDrawCompatibilityCharacter(uid);
            var partner = new PartnerData
            {
                Id = partnerId, TemplateId = templateId, Level = 1, Quality = 2, SkillList = [], UnlockSkillGroup = []
            };
            character.Partners = [partner];
            var player = CreateDrawCompatibilityPlayer(uid);
            Dictionary<int, long> expected = new()
            {
                [Inventory.Coin] = 500_000, [smallExp] = 3, [mediumExp] = 1, [largeExp] = 30,
                [unlistedExp] = 1, [smallOverclock] = 192, [largeOverclock] = 64
            };
            var inventory = CreateDrawCompatibilityInventory(uid, expected.Select(row => new Item { Id = row.Key, Count = row.Value }));
            Player.collection.InsertOne(player);
            Character.collection.InsertOne(character);
            Inventory.collection.InsertOne(inventory);
            int packetId = 67_300;
            using (LoopbackSessionHarness harness = new(character, player, inventory, "partner-quick-upgrade", startClientLoop: false))
            {
                void Feed(Dictionary<int, int> items, bool succeeds, int level, int exp, int cost)
                {
                    InvokeRegisteredRequestHandler(nameof(PartnerLevelUpRequest), harness.Session, ++packetId,
                        new PartnerLevelUpRequest { PartnerId = partnerId, UseItems = items });
                    if (succeeds)
                    {
                        expected[Inventory.Coin] -= cost;
                        foreach ((int id, int count) in items)
                            expected[id] -= count;
                        var pushed = ReadPushPayload<NotifyItemDataList>(harness, nameof(NotifyItemDataList), "CUB EXP debit");
                        AssertEqual(items.Count + 1, pushed.ItemDataList.Count, "CUB EXP push contains one balance per debit");
                        foreach (Item balance in pushed.ItemDataList)
                            AssertEqual(expected[balance.Id], balance.Count, $"CUB EXP balance for item {balance.Id}");
                    }
                    var response = ReadResponsePayload<PartnerLevelUpResponse>(harness, packetId, nameof(PartnerLevelUpResponse),
                        "CUB EXP response", maxPacketsToRead: succeeds ? 4 : 1);
                    AssertEqual(succeeds ? 0 : 1, response.Code, "CUB EXP response code");
                    if (succeeds)
                        AssertEqual((level, exp), (response.Level, response.Exp), "CUB EXP wire progression");
                    AssertEqual((level, exp), (partner.Level, partner.Exp), "CUB EXP in-session progression");
                    foreach (Item balance in inventory.Items)
                        AssertEqual(expected[balance.Id], balance.Count, $"CUB current balance for item {balance.Id}");
                }

                // The reported quick upgrade used one each of 30112 and 30111 with a 4,000 coin fee.
                Feed(new() { [mediumExp] = 1, [smallExp] = 1 }, true, 10, 0, 4_000);
                Feed(new() { [smallExp] = 1 }, false, 10, 0, 0);

                var stages = TableReaderV2.Parse<PartnerBreakThroughTable>().Where(row => row.PartnerId == templateId)
                    .OrderBy(row => row.BreakTimes).ToArray();
                int[] remainingStageExp =
                [
                    TableReaderV2.Parse<PartnerLevelUpTemplate502Table>().Single(row => row.Level == stages[1].LevelLimit).AllExp,
                    TableReaderV2.Parse<PartnerLevelUpTemplate503Table>().Single(row => row.Level == stages[2].LevelLimit).AllExp,
                    TableReaderV2.Parse<PartnerLevelUpTemplate504Table>().Single(row => row.Level == stages[3].LevelLimit).AllExp
                ];
                for (int stage = 0; stage < stages.Length - 1; stage++)
                {
                    InvokeRegisteredRequestHandler(nameof(PartnerBreakThroughRequest), harness.Session, ++packetId,
                        new PartnerBreakThroughRequest { PartnerId = partnerId });
                    var pushed = ReadPushPayload<NotifyItemDataList>(harness, nameof(NotifyItemDataList), "CUB overclock debit");
                    foreach ((int id, int count) in stages[stage].CostItemId.Zip(stages[stage].CostItemCount))
                    {
                        expected[id] -= count;
                        AssertEqual(expected[id], pushed.ItemDataList.Single(item => item.Id == id).Count,
                            $"CUB overclock balance for item {id}");
                    }
                    var response = ReadResponsePayload<PartnerBreakThroughResponse>(harness, packetId,
                        nameof(PartnerBreakThroughResponse), "CUB overclock response", maxPacketsToRead: 4);
                    AssertEqual(0, response.Code, "CUB overclock succeeds");
                    AssertEqual((stage + 1, 1, 0), (response.BreakTimes, partner.Level, partner.Exp),
                        "CUB overclock resets level and EXP for the next stage");

                    if (stage == 0)
                    {
                        Feed(new() { [mediumExp] = 1, [smallExp] = 1 }, false, 1, 0, 0);
                        Feed(new() { [unlistedExp] = 1 }, false, 1, 0, 0);
                        Feed(new() { [smallExp] = 1 }, true, 3, 20, 1_000);
                    }
                    int requiredExp = remainingStageExp[stage] - (stage == 0 ? 100 : 0);
                    int food = (requiredExp + 499) / 500;
                    Feed(new() { [largeExp] = food }, true, stages[stage + 1].LevelLimit, 0, food * 5_000);
                }
            }

            var saved = Character.collection.Find(row => row.Uid == uid).Single().Partners.Single();
            AssertEqual((3, 30, 0), (saved.BreakThrough, saved.Level, saved.Exp), "CUB Lv.30 progression is persisted");
            var savedItems = Inventory.collection.Find(row => row.Uid == uid).Single().Items.ToDictionary(item => item.Id, item => item.Count);
            AssertEqual(expected.Count, savedItems.Count, "CUB upgrade creates no items");
            foreach ((int id, long balance) in expected)
                AssertEqual(balance, savedItems[id], $"CUB persisted balance for item {id}");
        }
        finally
        {
            Player.collection = originalPlayers;
            Character.collection = originalCharacters;
            Inventory.collection = originalInventory;
            client.DropDatabase(databaseName);
        }
    }
}
