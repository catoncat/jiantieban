# jiantieban Makefile — CLT-only 构建链
# 注意：CLT 的 SPM 在 release 下编译多 target 有 bug（tests target 解析不了 Core），
# 所以 release 构建必须用 --product 指定单个产物；测试跑 debug 即可。

BIN := .build/release/jiantieban
TESTBIN := .build/debug/jiantieban-tests

.PHONY: build test bench run clean measure bundle sign app

app: bundle sign

build:
	swift build -c release --product jiantieban

test:
	swift run jiantieban-tests

bench: build
	rm -rf /tmp/jiantieban-bench
	JIANTIEBAN_HOME=/tmp/jiantieban-bench $(BIN) bench 100000

run: build
	$(BIN)

clean:
	rm -rf .build build

bundle:
	Scripts/bundle.sh

sign:
	Scripts/sign.sh

# 对指定 PID 做内存/CPU 取证（M2 面板跑起来后用）
# 用法: make measure PID=12345
measure:
ifndef PID
	$(error 用法: make measure PID=<pid>)
endif
	Scripts/measure.sh $(PID)
