# 验证范围与已发现问题

机器结果及原始路径由`evidence-index.json`汇总。通过仅限记录的源、参数和输入；未运行部分不推定通过。

| 层次 | 已做检查 | 边界 |
| --- | --- | --- |
| 软件参考 | H1–H4、bimodal/gshare、缩放TAGE/SC/loop契约单测；未修改作者完整参考 | 作者参考不是同预算实现；立即训练下分别检查ROI冷启动和自然请求前缀 |
| 模块状态 | 四种TAGE/SC/loop组合各3个seed；解析与推测各36,000周期。逐查询上下文、所有有效表状态、历史、增量折叠逐位比较 | 另完成8组几何×3seed×4000事件，共96,000次全状态比较；随机测试不是形式证明 |
| 变异 | 饱和、索引、历史快照、useful、分配bank、SC符号/阈值、loop退出、alternate选择器9项 | 每项都需实际编译运行并由独立模型检出；未实现推测RAS，未做该恢复变异 |
| 形式 | Yosys SAT对三种静态/动态选择的组合函数检查全部输入 | 另对小几何SC+loop进行四步invalidate优先级BMC；初始复位是明确假设。不代表全预测器或整核形式证明 |
| 整核接线 | NSL解析历史、N0推测历史：真实query/train事件与软件全状态比较；快照随64bit动态ID检查；开发程序退休PC/指令/next-PC序列对齐 | observer不驱动DUT；宽ID不能被短frontend_tag代替 |
| 早期目标 | 6个seed×12,000周期，请求/响应/交付独立反压，维护暂停、外部恢复、响应同拍恢复、受阻请求排空 | B/J及独立return/RAS路径各六组；加入返回预测受阻时栈顶变化测试。普通JALR和多级BTB尚无RTL |
| 架构安全 | B0、E0、NSL、N0-spec分别运行既有fetch、FENCE.I、dirty-victim/clean故障恢复、精确异常回归 | cache单测不单独证明前端交互；整核FENCE测试另有错误路径store/MMIO检查 |
| ISA | 4配置×10个NEMU cpu-tests | 比对32个GPR、PC及mstatus/mtvec/mepc/mcause/mtval。没有逐项比较全部CSR、内存或MMIO；不检验预测算法是否训练正确 |
| 应用 | 原代理及上游片段的固定参考结果 | checksum一致不替代模型/RTL状态比对；输入代表性另列 |

## 本轮修正与失败证据

1. `next_pc != pc+4`不能作为actual_taken：目标为PC+4的taken分支会被误判。EX结果增加一位实际比较结果，预测训练与PMU使用该位；已有taken/NT同next-PC定向测试。
2. 旧T16首次运行误传4bit历史，被原有检查拒绝。修为16bit后重建新目录；原失败不算算法负结果。
3. 新RTL首次编译遇到SV保留字`weak/context`，已更名；保留失败日志。
4. 随机维护暂停暴露IFU吞吐断言缺少prediction_enable前提。补前提并增加禁止期间不得查询的断言；没有关闭握手、身份或恢复断言。
5. 首次新TAGE综合在Slang/Yosys优化阶段遇到32bit临时int的init冲突。改为有符号3bit bank索引/9bit SC和，模型逐状态复测通过；不增加流水级。
6. 第一次推测历史整核比对暴露observer漏记“仅flush”的时钟沿；补记录后再次检查。随后发现仿真退出使最后一条post-edge记录未写完，延迟2个测试台时间单位结束，CPU计分周期不变。失败轨迹和日志仍在。
7. 真输入首版校验在ROI内，已单列v1并新增v2计分边界；不会把该软件测量修正计作硬件加速。

新增加的推测历史恢复只在明确开关下工作。默认仍关闭static/early/SC/loop/spec实验；spec与early组合主动拒绝，尚未实现保留老查询时的历史重放。

8. 返回预测原型直接读取解析RAS，受阻期间老call训练可改变已展示载荷。修复为首次受阻保存34bit状态，正常路径直通；六个seed×12000周期通过。独立副本删除保持选择后，稳定性断言确实失败。初版R0/ER0/NER0不作为安全候选。
9. 推测历史除条件方向错误外，还需处理普通指令/LSU/JAL/JALR误插入conditional历史；定向检查覆盖ready、老异常阻塞与自身异常。
10. 修复后R0-held、NSmallER-held、H2E-narrow各运行四项安全目标及10个NEMU输入；观察器开/关另检查四配置×两输入，RESULT周期、退休数、digest与校验结果相同。
11. 旧压缩BTB重新执行五种配置，每种20,065事件，包含32个位宽边界、跨64KiB范围、迁移、拒绝、失效和随机训练。是本轮复测，未宣称新压缩算法。

## BTB联合补测

独立C++参考保存完整PC，RTL保存tag和组索引；39组配置比较1,404,000次查询及
31,104,000个表项状态。默认逻辑另复现3,234,632次真实基线查询。
索引、准入、RRIP插入、RRIP失效状态及valid失效五种变异均被检出；
RRIP无效行状态契约失败不等同于一次可观察错误跳转，valid变异单独覆盖旧目标残留。

BTB新组合的十个配置分别运行10项NEMU输入和4项安全目标，共100项ISA比较、40项安全目标。
这里只计BTB扩展及当前H2E复测，未把旧的全部实验混成一个“都通过”的数字。
配置与日志见`evidence-index.json`下的`isa/difftest/results.json`及各`safety/*/results.json`。

NSL＋BTB32/fold另用真实整核query/train检查一个代理和一个上游jsmn输入：
313,117个事件、77,741次训练，查询快照和更新后完整状态均与Python参考一致。
开/关观察器时RESULT/COUNTERS/DETAIL完全相同，见`btb-joint-observer-equivalence.json`。
BTB容量/方向实验使用不同预测路径，不能用“相同绝对cycle”配对不同配置的动态指令。

长输入使用同一可执行文件的两个被动窗口。`paired-window-equivalence.json`逐对检查
全程序周期、退休数、digest和checksum相同；窗口本身覆盖不同调用数，不能要求窗口周期相同。
`learning-curves.csv`记录7,161个开发阶段分支窗口；它描述输入阶段变化，不宣称8次前缀已经充分收敛。

最终五种配置均完成交付源码核验：每个仿真快照包含70份RTL，综合活动文件集包含56份RTL。
H2E早期综合先于默认关闭的BTB索引/准入开关，因此按相同流程重新映射当前源码；
网表和SDC哈希、面积、700MHz全部时序检查结果与冻结值一致。
其他四种配置的原综合源码已与交付源码一致。见`ppa-delivery-audit.json`；
这项核验没有改变候选、频点或保留集结果。
