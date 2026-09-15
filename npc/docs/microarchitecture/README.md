# NPC 微架构设计记录

本目录保存具体模块的需求、边界、接口契约、微架构选择和正确性不变量。RTL 旁边的注释
只解释局部代码；架构路线、开发规范、实验结果和学习总结分别由上级分类目录维护。

新增模块时，从
[`MODULE_DESIGN_RECORD_TEMPLATE.md`](../development/MODULE_DESIGN_RECORD_TEMPLATE.md)
复制一份模块记录，再进入 RTL 实现。体系结构的最终依据是
[`ARCHITECTURE_PLAN.md`](../architecture/ARCHITECTURE_PLAN.md)，命名和源码组织的最终依据是
[`NAMING_GUIDE.md`](../development/NAMING_GUIDE.md)。

## 固定开发流程

1. 编写RTL前创建或更新模块设计记录，写清问题、可测量目标、所有权边界、接口契约、
   状态和数据结构、正确性不变量以及验证计划。
2. 至少对比两个相关的开源实现或标准。记录从每个来源学到的具体机制，并说明本地设计
   选择采用、调整还是拒绝；不能只复制代码结构而不理解其契约。
3. 在架构计划中冻结第一个实现检查点。后续修改若与冻结决策冲突，必须新增
   决策记录，说明证据和迁移办法。
4. 教学TODO必须紧邻真正的插入位置，并明确声明、默认值、状态转移、边界条件和测试。
5. 每次只实现一个能够独立验证的边界。未完成文件不进入活动filelist，确保上一个验证
   检查点始终可运行。
6. 验证后向[`EXPERIMENT_LOG.md`](../verification/EXPERIMENT_LOG.md)追加命令、配置、
   commit、结果和分析。设计变化后不得覆盖
   旧数据。
7. 模块检查点结束时，将有证据支持的开发心得追加到
   [`LEARNING_JOURNAL.md`](../learning/LEARNING_JOURNAL.md)。稳定结论回写
   模块设计记录；没有实验支持的判断必须留在“仍需验证”，不能写成既定事实。

## 设计记录准入检查

一份模块设计记录只有回答以下问题后，才可以进入RTL实现：

- 本模块拥有哪些信息，哪些状态和策略必须留在其他模块？
- 哪次握手开始事务，哪次握手结束事务，反压期间哪些字段必须稳定？
- 哪些状态是架构态、推测态、可替换状态或仅供仿真的状态？
- 复位、重定向、异常、失效和下游阻塞时分别发生什么？
- 目标延迟和吞吐是多少，哪条组合路径可能成为时序瓶颈？
- 哪些断言用于发现损坏、重复、丢失、过期响应或协议违规？
- 哪些性能计数器能够证明目标负载确实受益？

## 当前记录

- [`FETCH_PREDICTOR_DESIGN_RECORD.md`](FETCH_PREDICTOR_DESIGN_RECORD.md)：当前 RV32 预测控制与
  BHT、BTB、RAS 的模块边界、查询对齐、训练时序及拆分验证。
- [`ICACHE_DESIGN_RECORD.md`](ICACHE_DESIGN_RECORD.md)：第一版I-cache检查点及其向高性能
  前端演进的路径。
- [`DCACHE_DESIGN_RECORD.md`](DCACHE_DESIGN_RECORD.md)：首版write-back/write-allocate
  D-cache、PMA路由、I/D共享内存仲裁和面向AI负载的后续演进边界。
- [`BRANCH_PREDICTION_DESIGN_RECORD.md`](BRANCH_PREDICTION_DESIGN_RECORD.md)：退休控制流
  trace、Branchsim设计空间探索以及方向、间接目标和返回预测的演进依据。
- [`PIPELINE_DESIGN_RECORD.md`](PIPELINE_DESIGN_RECORD.md)：顺序流水级边界、RAW/结构/
  控制冒险、精确flush和后续forwarding路线。
- [`EXPERIMENT_LOG.md`](../verification/EXPERIMENT_LOG.md)：I-cache接入前基线和后续实验结果。
- [`LEARNING_JOURNAL.md`](../learning/LEARNING_JOURNAL.md)：可复用经验和尚未证实的假设。
