# 本机正则验证修正

> 本分支仅保存研究摘要；文中原始日志、镜像和快照路径是历史来源，原始 result 已清理，详见[发布范围](../../README.md)。

原Python参考未改变。tiny-regex-c的re_match与宿主libc导出的同名函数发生动态符号抢占，
共享对象内的调用没有使用vendor实现，导致所有字符都走单字节fallback。
独立调用vendor re_match逐token与Python一致；全fallback校验值0x073b8545与失败值相同。
绑定共享对象自身符号(-Wl,-Bsymbolic)后得到参考值0x3d7a0ba5。
RV32镜像为静态链接，不存在这一宿主符号冲突。前一次将空白表达式换成库支持的\s，仍未解决宿主问题，保留两次失败目录。

补充构建记录：freestanding stdio头最初缺少inih未使用的文件接口声明，补齐声明后由链接器
丢弃文件I/O路径；没有让负载实际调用文件系统。另一次HEX导出没有补齐最后不足4字节的一组，
现与已有镜像生成规则一致补零。对应目录images-third-stdio-header与images-fourth-hex-padding
及日志保留。新建目录重构全部22个镜像，另以image-reproduction.json确认实际BIN/HEX逐字节一致。

history-observer.log中的首个失败是结果解析器仅比较COUNTERS行，而原schema合并COUNTERS与
DETAIL。硬件RESULT及各计数原本一致。补齐DETAIL解析后继续验证，未降低计数一致性要求；
原始失败及说明保留在history-observer/parser-failure.json。
