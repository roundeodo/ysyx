# From the interview repository; no commits/pushes are performed.
export NPC_HOME="$PWD/npc"
python3 npc/docs/verification/data/rv32-readability-20261004/check_equivalence.py
make -C npc NPC_CONFIG=rv32-balanced git_commit= lint-npc
make -C npc NPC_CONFIG=rv32-balanced git_commit= test-fetch test-fence-i test-precise-exception
# This old contract is known to fail under balanced, identically before these edits:
make -C npc NPC_CONFIG=rv32-balanced git_commit= test-predictor
# Passed legacy-config exact build command is in logs/legacy-predictor/predictor/manifest.json.
python3 npc/scripts/test_selection_replacement.py --output npc/result/readability-review-replacement --policies 13
# State-comparison script uses result/branch-v3/tage-scl by default. This run changed
# only ROOT to result/readability-review-current/tage-scl through an in-memory wrapper.
python3 npc/tools/branch_v3/check_tage_scl.py
# Synthesis frontend, not mapped PPA or STA:
yosys -m slang -s npc/docs/verification/data/rv32-readability-20261004/read.ys
