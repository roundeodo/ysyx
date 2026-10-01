# V3 分支预测实验结构

稳定默认仍为BHT16、BTB16/2路、RAS4；所有新增机制默认关闭。实验不改变RV32I后端、cache容量或存储服务。参数、测量与选择记录见[研究目录](../research/branch-v3/plan.md)。

## 原有寄存边界与真值

请求PC并行查询BHT、BTB、RAS，合并后进入原有一拍预测响应寄存器；IFU预测请求队列和fetch buffer保留空队列直通。模块拆分不增加流水级。

EX的实际条件比较结果随现有结果寄存器保存为`branch_taken`，在解析交付时训练与计数。不能用`next_pc!=pc+4`代替：目标恰为PC+4的taken分支仍须写入taken历史。

## 静态/动态选择

`branch_choice`是无状态组合选择：0用动态，1在信息有效时用BTFNT，2在二位counter为1/2时用BTFNT、为0/3时用动态。请求侧只有BTB命中且kind为conditional才有静态信息；其B指令位移必在有符号13bit范围，因此用`target[12:0]-pc[12:0]`的符号位。返回侧直接用B指令的符号位。

H2的强弱规则只用于真实二位counter。新TAGE输出的两位编码仅传递方向，不伪造已校准置信度。H1/H3/H4是另列软件模型，未混入此模块。

## 可消融的缩放TAGE

`BRANCH_DIRECTION_POLICY=5`选择新模块，与旧policy3/4分开。base、每个tagged表容量、表数、tag宽度和历史长度组独立配置；默认base32、3×16 tagged、8bit tag、3/7/16方向历史。已测试几何为2/3表、base16至128、tagged8至64、tag6至10bit、最长32bit历史，越界或快照超过192bit时拒绝构建。

数据流为：历史增量fold → base/tagged并行读 → 最长provider及alternate → USE_ALT弱项选择 → 可选SC → 可选loop → 原预测响应寄存器。没有新增查询或训练级。

| 状态 | 写入与保持 | 清除/恢复 |
| --- | --- | --- |
| base二位counter、tagged有效/tag/有符号3bit counter/2bit useful | 解析时按查询快照定位，以当前counter更新；provider已替换时不训练新住户。TAGE判断错误时优先分配最短可用的更长表，否则压力老化 | invalidate清tagged有效位，base保留；无效payload不复位 |
| 4bit USE_ALT选择器 | provider弱且raw/alternate分歧时训练 | 复位初始化，普通flush不改变 |
| 全局方向历史和index/tag fold | resolved模式按训练推进；spec模式按已接受、已识别条件分支的实际采用方向推进 | invalidate清空；spec恢复从检查点或解析历史重建fold |
| SC的3×entries个有符号5bit权重及5bit阈值 | PC、短全局历史、折叠历史+TAGE方向三特征；中心化和加±4先验；错误或低margin更新；阈值1至31 | 复位初始化，失效时保持但不得同拍训练 |
| loop的4项全PC身份、8bit trip/current、2bit confidence及direction | 稳定trip后预测退出，变长重学，计数溢出撤销可信度 | invalidate清有效位；当前缩放版没有作者完整age/替换组织 |
| 查询快照 | 沿现有指令载荷保存索引、tag、provider/方向、SC/loop选择信息及epoch；位宽按配置派生 | 取消指令不训练，失效后拒绝旧epoch |

这不是作者8KB TAGE-SC-L的等比例实现：未实现其完整local/path/IMLI、bank交织、age与选择性访问。软件完整参考和本模块的不同在研究记录单列。

## 推测历史恢复

spec模式另存解析GHR；接受条件查询时保存推进前的历史。EX解析发现漏插历史、方向不符、或者实际并非条件分支但曾插入历史时，即使下一PC正确，也必须恢复。

条件分支在EX结果交付边界用其检查点加实际方向修复；实际JAL/JALR误插历史时在该边界恢复解析历史。普通执行和LSU的错类型在EXU交付边界触发恢复。异常与更老恢复优先，受阻或不允许交付时不提前发恢复。

表训练始终在解析时进行。当前不支持spec与任一种局部early override组合：后者保留老的未解析指令，需要额外年龄重放协议，配置检查会明确拒绝。

## I-cache返回后的早期目标

`BRANCH_EARLY_TARGET`在取回B/J指令后用PC+立即数精确计算目标；`BRANCH_EARLY_RAS`按x1/x5、rd/rs1和imm=0提示识别返回并使用解析RAS栈顶。一般JALR不由立即数猜目标。方向counter随原预测快照传递。

两者共享局部恢复：只有当前fetch_entry握手、访问无错、目标对齐且下一PC与原预测不同才纠正。当前指令与更老fetch buffer内容保留；年轻预测响应和未展示请求取消。已展示且受阻的cache请求保持VALID和payload，之后按旧epoch排空。EX/trap/FENCE.I的外部恢复优先。

直接目标没有新寄存级；代价为译码、加法、目标选择/比较和恢复扇出。AXI refill数据可直通到此路径，因此“没有额外周期”仍可能显著降低频率。

解析RAS会在返回响应受阻时被老call/ret改变。第一次`valid&&!ready`时才保存RAS有效位、目标与hold存在位，共34bit；保持到交付或外部取消。正常直通不保存、不增加周期。不能停住老分支训练来维持接口稳定；EX仍负责最终目标校验。

验证端口和被动观察器不进入正常综合。每次增加状态、等待或组合反馈都以接口测试、实际周期及全核STA/面积确认，不能按寄存器数量直接推断优劣。
