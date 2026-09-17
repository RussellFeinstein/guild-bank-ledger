-- Hand-written fixture in the shape WoW's SavedVariables writer produces
-- for src/AuditCapture.lua. Two sessions, on two addon versions.
--
-- The key order inside session 1 is the point of this file and is
-- deliberate: `dropped` sits ABOVE `startedAt`, because WoW serialises a
-- table in pairs() order and a real capture looks like this. A reader that
-- brackets a session by the line its `startedAt` appears on reads the NEXT
-- session's dropped counters as this one's, which is exactly the mistake
-- that produced a wrong conclusion on 2026-09-08. Anything reading this
-- file must address sessions by index.
--
-- Session 2's sort channel carries three complete sort runs plus one
-- leading `Sort plan:` line with no run of its own, which is what
-- /gbl sortpreview emits. Run 2 is an abort; run 3 is a bags-on run.
--
-- The plan line at 1789172451 sits AFTER run 1's terminal line and repeats
-- run 1's plan with a different timing figure. That is the /gbl deviations
-- the Sort tab runs after every executed sort, and it is here for two
-- reasons: it must not be folded into either neighbouring run, and it is
-- the pair that proves a plan signature ignores the milliseconds.

GuildBankLedgerAuditDB = {
	["schemaVersion"] = 1,
	["sessions"] = {
		{
			["dropped"] = {
				["sync"] = 0,
				["sort"] = 692,
				["system"] = 0,
			},
			["realm"] = "TestRealm",
			["guild"] = "Test Guild",
			["protocolVersion"] = 3,
			["player"] = "Tester",
			["startedAt"] = 1789166400,
			["addonVersion"] = "0.39.3",
			["entries"] = {
				["sync"] = {
					{
						["ts"] = 1789166460,
						["level"] = "INFO",
						["message"] = "HELLO round Someone: verdict=identical reply=sent",
					},
				},
				["sort"] = {
					{
						["ts"] = 1789166460,
						["level"] = "INFO",
						["message"] = "Sort plan: 4.2ms, 0 ops, 0 deficits, 0 unplaced (input: 603 slots / 7 tabs) unviewable:none [T1:59 T2:98]",
					},
					{
						["ts"] = 1789166520,
						["level"] = "WARN",
						["message"] = "Sort op 3/9 skipped: Bag1/25 locked, wanted 20 x item:100",
					},
				},
				["system"] = {},
			},
		},
		{
			["startedAt"] = 1789172400,
			["addonVersion"] = "0.39.4",
			["protocolVersion"] = 3,
			["player"] = "Tester",
			["realm"] = "TestRealm",
			["guild"] = "Test Guild",
			["dropped"] = {
				["sync"] = 0,
				["sort"] = 0,
				["system"] = 0,
			},
			["entries"] = {
				["sync"] = {},
				["system"] = {
					{
						["ts"] = 1789172400,
						["level"] = "INFO",
						["message"] = "Bank opened",
					},
				},
				["sort"] = {
					{
						["ts"] = 1789172401,
						["level"] = "INFO",
						["message"] = "Sort plan: 3.0ms, 0 ops, 0 deficits, 0 unplaced (input: 600 slots / 7 tabs) unviewable:none [T1:59]",
					},
					{
						["ts"] = 1789172410,
						["level"] = "INFO",
						["message"] = "Sort: starting execution of 12 ops, cadence 1.0s (ping 40ms) bags=off",
					},
					{
						["ts"] = 1789172411,
						["level"] = "INFO",
						["message"] = "Sort plan: 5.1ms, 12 ops, 0 deficits, 0 unplaced (input: 600 slots / 7 tabs) unviewable:none [T1:59]",
					},
					{
						["ts"] = 1789172412,
						["level"] = "INFO",
						["message"] = "  phases: P0 merge=0(free=0) P1a assign=12 P1b spill=0(top=0,r=0,l=0,fe=0,unp=0) P2 pivot=1(abort=0) P3 sweep=0 P4 pack=0",
					},
					{
						["ts"] = 1789172430,
						["level"] = "INFO",
						["message"] = "Sort: pass 1 left 2 move(s); re-running",
					},
					{
						["ts"] = 1789172450,
						["level"] = "INFO",
						["message"] = "Sort: complete in 40.0s - 2 passes, 14 ops issued, 0 remaining, avg 1.10s/op (cursorStuck=0 stalls=0 rescans=1)",
					},
					{
						["ts"] = 1789172451,
						["level"] = "INFO",
						["message"] = "Sort plan: 4.8ms, 12 ops, 0 deficits, 0 unplaced (input: 600 slots / 7 tabs) unviewable:none [T1:59]",
					},
					{
						["ts"] = 1789172500,
						["level"] = "INFO",
						["message"] = "Sort: starting execution of 5 ops, cadence 1.0s (ping 40ms) bags=off",
					},
					{
						["ts"] = 1789172501,
						["level"] = "INFO",
						["message"] = "Sort plan: 2.2ms, 5 ops, 1 deficits, 2 unplaced (input: 600 slots / 7 tabs) unviewable:T5 [T1:59]",
					},
					{
						["ts"] = 1789172520,
						["level"] = "INFO",
						["message"] = "Sort: aborted (bank closed) in 20.0s - 1 passes, 3 ops issued, 2 remaining, avg 1.00s/op (cursorStuck=0 stalls=0 rescans=0)",
					},
					{
						["ts"] = 1789172600,
						["level"] = "INFO",
						["message"] = "Sort: starting execution of 8 ops, cadence 1.0s (ping 40ms) bags=on",
					},
					{
						["ts"] = 1789172601,
						["level"] = "INFO",
						["message"] = "Sort plan: 6.0ms, 8 ops, 0 deficits, 1 unplaced (input: 600 slots / 7 tabs) bags:4/9(fill=1,spill=3,stay=1,ignored=5,bound=0,locked=0,nolink=0) unviewable:none [T1:59]",
					},
					{
						["ts"] = 1789172602,
						["level"] = "INFO",
						["message"] = "  bags stay: item:100 x20 at Bag2/18 (overflow-full)",
					},
					{
						["ts"] = 1789172640,
						["level"] = "INFO",
						["message"] = "Sort bags: 3 deposit(s) issued, 0 skipped, still in bags: 20 (20 unplaceable)",
					},
					{
						["ts"] = 1789172641,
						["level"] = "INFO",
						["message"] = "Sort: complete in 41.0s - 1 passes, 8 ops issued, 0 remaining, avg 1.20s/op (cursorStuck=0 stalls=0 rescans=0)",
					},
				},
			},
		},
	},
}
