FUZZIT_API_KEY="${FUZZIT_API_KEY:-}"

[ -s ./suite/fuzz/fuzz_bindisasm2 ] || exit 0

if [ ${TRAVIS_EVENT_TYPE} -eq 'cron' ]; then
    FUZZING_TYPE=fuzzing
else
    FUZZING_TYPE=sanity
fi
if [ "$TRAVIS_PULL_REQUEST" = "false" ]; then
    FUZZIT_BRANCH="${TRAVIS_BRANCH}"
else
    FUZZIT_BRANCH="PR-${TRAVIS_PULL_REQUEST}"
fi

FUZZIT_ARGS="--type ${FUZZING_TYPE} --branch ${FUZZIT_BRANCH} --revision ${TRAVIS_COMMIT}"
if [ -n "$UBSAN_OPTIONS" ]; then
    FUZZIT_ARGS+=" --ubsan_options ${UBSAN_OPTIONS}"
fi
wget -O fuzzit https://github.com/fuzzitdev/fuzzit/releases/download/v1.2.5/fuzzit_1.2.5_Linux_x86_64
chmod +x fuzzit
./fuzzit auth ${FUZZIT_API_KEY}
set -x
grep "$QA_FUZZIT" suite/fuzz/fuzzitid.txt | cut -d" " -f2 | while read i; do
    ./fuzzit c job ${FUZZIT_ARGS} ${i} ./suite/fuzz/fuzz_bindisasm2
done
set +x
