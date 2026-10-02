# 软件输入与测量边界

本轮均为RV32I/Zicsr/Zifencei，不含乘除法、Issue、ROB。编译命令、ELF/bin/input哈希和参考答案随每组manifest保存。

| 分组 | 输入与上游 | 当前用途 |
| --- | --- | --- |
| 原代理，新输入 | json_bpe、quant_loader、runtime_graph、tiny-regex-c、inih；开发2411/2418，验证2437/2442 | 开发10项。每组奇偶种子各一个，补原stream布尔覆盖缺口。代理不等同完整AI runtime |
| 新真实软件片段 | 未修改jsmn：`25647e692c7906b96ffd2b05ca54c097948e879c`，MIT；既有未修改miniz解压函数，版本见`tests/frontend_selection/vendor/manifest.json` | JSON模型元数据tokenization、压缩元数据装载。保留库的token数组、parse入口和DEFLATE状态机；本轮没有神经网络推理 |
| 新真实输入 | [GPT-2 config](https://huggingface.co/openai-community/gpt2/resolve/607a30d783dfa663caf39e06633721c8d4cfcd7e/config.json)，665B；[BERT config](https://huggingface.co/google-bert/bert-base-uncased/resolve/86b5e0934494bd15c9632b12f734a8a67f723594/config.json)，570B | 原始字节不改；浮点数字只解析为文本token，无F扩展需求。压缩采用zlib level6，输入/输出由Python独立校验 |
| 历史参照 | MicroBench test与NEMU cpu-tests | 回归，不用其总分替代目标应用数据 |
| 最终保留 | 2467/2474及预定词表区间 | 仅在selection-freeze写入后生成/运行；结果见final-results，不能用于重新选参 |

新输入来源、commit、许可证标识与hash在`tests/branch_v3/upstream-manifest.json`。`fetch_inputs.py`优先使用这些固定URL和hash，不在复现时读取新的main/master。

## 正确性与计分

所有输入先经Python参考、native C、RV32镜像构建检查；RTL以相同镜像、结果和计分PC运行。二进制转换出的HEX在运行前再次核验。

`real-images`为第一版：输出校验hash在ROI内。此版本保留供追溯，但不能把校验循环带来的停顿归因于上游库。
`real-images-v2`将校验移到ROI外，并为每次调用保留独立输出，避免后一次覆盖前一次错误。开始/结束标记仍是程序中固定两条NOP，候选之间相同；验证返回值不变。

每个真实输入调用三次，当前报告是包含冷启动的整体窗口。它不是已证明收敛的自然稳态，也不能把重复同一配置的三次运行视为三个独立样本。新增streams使用两个真实config和四个不重复词表对象；冷窗口计六次调用，暖窗口计相同两请求前缀后的四次不同调用。词表按原始key顺序预先分开发[0,256)、验证[256,512)、最终[512,768)，见stream-inputs.json。这是元数据tokenization，不是完整GPT-2 BPE；256 token/request、128KiB RAM限制不变。自然前缀并未证明预测器状态收敛；真实大模型runtime仍未覆盖。

## 存储与时间

独立RTL测试台：统一128KiB RAM、共享AXI服务、100ns首响应/10ns后续beat，转换依赖实际CPU频点；默认无随机反压，配对seed97531。它不包含完整SoC/APB设备，不与原生SoC时间混为一谈。

`run_frequencies.py`在每个STA合法频点重新运行RTL；同频比较取候选共同合法频点。CPU执行时间为同窗口cycles/frequency，不能用宿主仿真walltime，也不能只将700MHz周期数按比例换算。

原生MicroBench单列device-clock-v1、100MHz设备计时；本轮没有改变该延迟模型。原代理结果与新真实片段结果分别报告，未依据某个候选结果重新给家族加权。

## 较长的真实请求流

`build_long_streams.py`在运行候选前冻结`tests/branch_v3/long-stream-inputs.json`：
从同一已固定版本词表取三个互不重叠键区间，开发/验证/最终区间分别为[1024,9728)、[17408,26112)、[33792,42496)。
每个请求64个不同键，8个前缀请求之后分别执行8/32/128个不同请求；冷窗口也计入前缀。
保留所有解析/解压输出，在ROI结束后核验；Python参考与宿主C先对齐，再运行RV32I镜像。
128规模共136次不同请求、125,063字节开发原始输入；并非重复同一个数据块。

为容纳输出，独立测试台RAM从128KiB参数化为2MiB，仍在原4MiB可缓存PMA内。
该改变只扩展可寻址存储，不改cache、总线并发度、100ns首拍/10ns节拍或计时规则。
旧镜像在两种RAM大小下必须逐项周期、退休、digest、校验和一致，才开始比较长输入。
新增8192条件分支窗口计数与静态PC/32B代码行统计完全被动，关闭大事件trace以控制磁盘。

这个扩展检查请求数、自然预热和阶段变化，不增加解析器自身的代码种类；仍不能代表完整边缘AI应用或所有控制流工作集。
最终区间仅在冻结候选后生成/运行；开发规模结果不替代最终验收。

### 冷/暖窗口的额外审计

原六请求stream与第一版long分别按`FIRST_MEASURED=0/2/8`编译cold/warm，
因此代码布局和外层循环分段也会改变。它们在同一镜像的硬件A/B比较仍然有效，
但cold对warm的差异不能全部归为预热；早先“自然前缀”描述不足以消除这个混杂因素。
第一版脚本和输出保留，原始脚本副本在`streams-long-development/build_long_streams.original.py`。

补测使用`build_long_streams.py --paired-windows`和`upstream_stream_windows.S`：
始终执行8个前缀请求及随后8/32/128个请求，仅改变测试台观察的起点PC。
每对cold/warm的`image.bin`必须逐字节相同；运行时再检查total_cycles、all_retired、digest和checksum相同。
`streams-long-paired-development`保存这组输入。本轮先对所有长候选统一测128规模的两种软件、两种窗口，
共四个窗口；既不按候选选择窗口，也不把旧的布局变化当作预热收益。

## 长请求的阶段性记录

`learning-curves.csv/json`导出七个合法频点候选的7,161个开发窗口，每窗8,192个已解析条件分支，
末尾不足一窗仍保留。`first/last`是CPU周期，不能当作退休序号；`missing`包含故意不准入的NT，
不能直接解释为有用目标不足。

同镜像miniz的128次暖窗口包含2,271,454个条件事件、183个控制流PC、162条已退休32B代码行。
这确实扩大了动态测量，仍只是一类解压程序的代码范围。基线四个阶段的raw错误率约
10.44%、10.74%、10.98%、11.14%，NSL/BTB32约4.86%、4.98%、5.17%、5.13%。
输入本身随请求改变，不能将这些变化全部归于训练，更不能由长运行时间推断覆盖了所有边缘AI控制流。
