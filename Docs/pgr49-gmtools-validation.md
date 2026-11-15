# PGR 4.9 client validation

Use a copy of the supported client and a disposable launcher profile with its own MongoDB and character. Run once after Setup and again after restarting both game and managed server. Record the release commit, client region/version and the observed results.

- [ ] Open GM Tools while the launcher-managed game is running. Load the correct UID in GM Player.
- [ ] Set Commandant Level 120. Verify the client updates and the same UID retains Level 120 on relog and restart.
- [ ] Preview a supported guide group, apply it with the intended reward policy, then reopen the guide and verify completion and reward state.
- [ ] Search for an item in Item Finder, check the intended template ID, grant one unit and verify the balance after relog.
- [ ] Wear six Memories and run Bulk Upgrade with two or more below cap and the required materials owned. Verify worn slots and progression after relog.
- [ ] Repeat with Auto Exchange enabled, a shortage of an Overclock material and enough currency `62738`. Verify the item credited, exact currency debit and Memory progression.
- [ ] Run CUB Quick Upgrade to phase 3 Lv.30 with material `30112` present. Verify its debit and CUB level after restart.
- [ ] As a nonmember, check that Material Shop opens and direct Guild shop access or purchases are refused. Repeat with a member to verify the intended permission state.
- [ ] Enable `gm-menu`, repeat launcher Setup, and confirm the toggle and mod persist. Deploy the next candidate and roll back once in the test install. Confirm the previous launcher, matching server, patch and mod configuration are loaded.

The server harness checks protocol responses, charges, persistence and GM control. A rendered in-game result requires observing the client.
