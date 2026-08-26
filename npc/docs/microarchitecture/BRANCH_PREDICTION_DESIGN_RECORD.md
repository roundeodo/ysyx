# 控制流预测设计记录

状态：当前实现与探索方法

## 1. 当前预测器

`riscv32_fetch_control_flow_predictor`位于I-cache之前，默认包含：

- 16项2-bit饱和计数器BHT，用于条件分支方向预测；
- 16项、2-way BTB，用于缓存已知控制流目标；
- 4项RAS，用于预测`ret`目标；
- JAL立即数目标计算；
- JALR在BTB/RAS未命中时回退到顺序PC。

这些默认值是功能配置，不是最终产品参数。BHT、BTB和RAS容量均由构建参数控制。

## 2. 查询路径

IFU向预测器发送PC、epoch和frontend tag。预测器返回：

- 是否预测taken；
- 预测目标；
- 预测来源和元数据；
- 与请求对应的PC和epoch。

IFU把预测结果和取指请求身份一起保存。I-cache响应回来后，二者组合成`fetch_entry_t`进入
fetch buffer。这样I-cache延迟和预测器延迟不会依赖提交级组合信号。

## 3. 更新路径

控制流指令在execute-result级解析真实taken和target。解析结果用于：

- 判断当前预测是否错误；
- 产生redirect；
- 更新BHT计数器；
- 安装或更新BTB entry；
- 根据call/return语义更新RAS。

预测状态不是架构状态。错误预测只影响性能，不能改变最终提交结果。flush和invalidate必须
清除正在返回的查询身份，但不需要恢复所有训练状态；进入乱序阶段后，RAS等推测状态需要
checkpoint或可恢复指针。

## 4. Branchsim

`npc/tools/branchsim`读取退休控制流trace，在不运行RTL的情况下评估预测算法。trace必须以
提交后的控制流为准，至少包含PC、指令类型、真实taken和真实target。

Branchsim用于：

- 比较always-not-taken、BTFNT、bimodal、gshare等方向算法；
- 探索BHT、BTB、way和RAS容量；
- 统计方向错误、目标错误、return错误和MPKI；
- 作为RTL性能事件的参考模型，检查训练或索引错误。

模型准确率不能直接等价为IPC。最终收益还取决于redirect发现级、错误恢复代价、I-cache
供给率和后端停顿。

## 5. 正确性不变量

- 每个预测响应必须对应一个仍有效的请求tag和epoch；
- redirect后旧epoch响应不能进入fetch buffer；
- BTB同一set最多命中一个way；
- RAS underflow/overflow行为必须确定且可验证；
- 更新只能使用已经解析的控制流结果；
- 预测错误不能阻止该指令自身精确提交。

## 6. 后续演进

按真实AI runtime和系统负载逐步评估：

1. 增大并bank化BTB；
2. gshare或TAGE类方向预测；
3. loop predictor；
4. indirect target predictor；
5. 可checkpoint的RAS；
6. FTQ保存预测历史和恢复信息；
7. 多分支、宽取指预测。

只有Branchsim和RTL计数器共同证明收益后，候选算法才进入主线。
