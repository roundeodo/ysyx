# 本轮综合脚本快照

这些脚本与所有面积/STA测量使用的历史toolflow逐文件相同。`yosys.tcl`保留上游
Efabless Apache-2.0声明；本地已有修改包括Slang读取、完整核的有界资源共享和显式
综合策略选择。`sta.tcl`默认不进行无向量功耗分析。来源和哈希见`manifest.json`。

工具二进制及NanGate45不重复提交。`prepare_selection_toolflow.py`将这份脚本与已经
安装的`bin/iEDA`、`pdk/nangate45`连接，创建新目录并记录二者哈希，不修改原安装。
`reproduce_icache_selection.py --toolflow 新目录`使用这份配置；工具及库版本不同就
是新实验环境，不能假定复现相同面积或频率。
