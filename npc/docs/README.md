# NPC 文档中心

本目录是 NPC 项目的唯一文档入口。RTL 目录只保存源码和紧邻实现位置的局部注释；跨模块
契约、架构决策、开发规范、实验结果和学习记录统一放在这里。

除标准名称、协议字段、代码标识、命令、路径和 URL 外，正文统一使用中文维护。

## 目录结构

| 目录 | 内容 | 主要读者 |
| --- | --- | --- |
| [`architecture/`](architecture/) | 产品场景、AI 负载模型、体系结构路线和冻结决策 | 全体开发者 |
| [`development/`](development/) | 命名、参数化、模块化、评审和设计记录模板 | RTL 与验证开发者 |
| [`interconnect/`](interconnect/) | AXI、APB、片上互连和协议迁移记录 | SoC 与存储子系统开发者 |
| [`microarchitecture/`](microarchitecture/) | I-cache 等具体模块的设计记录 | 模块所有者与评审者 |
| [`verification/`](verification/) | 可复现实验、性能结果和回归记录 | 验证与性能分析人员 |
| [`learning/`](learning/) | 从设计和实验中提炼的学习记录 | 当前及后续学习者 |

历史上已经被新决策替代的文档放入对应目录的 `archive/`。归档文件只能用于追溯，不能作为
当前实现依据。

## 权威文档

- [完整AXI4互连架构](interconnect/AXI4_ARCHITECTURE.md)：当前主链边界、事务能力和后续扩展规则。

- 最终产品和架构路线：[`architecture/ARCHITECTURE_PLAN.md`](architecture/ARCHITECTURE_PLAN.md)
- P2配置和宽度解耦：[`architecture/P2_CONFIGURATION_PLAN.md`](architecture/P2_CONFIGURATION_PLAN.md)
- AI 工作负载依据：[`architecture/AI_WORKLOAD_MODEL.md`](architecture/AI_WORKLOAD_MODEL.md)
- 固定开发流程：[`development/DEVELOPMENT_PROCESS.md`](development/DEVELOPMENT_PROCESS.md)
- 命名和源码组织：[`development/NAMING_GUIDE.md`](development/NAMING_GUIDE.md)
- 模块设计模板：[`development/MODULE_DESIGN_RECORD_TEMPLATE.md`](development/MODULE_DESIGN_RECORD_TEMPLATE.md)

当源码、TODO、旧文档与上述权威文档冲突时，应先停止扩大改动，更新决策记录并明确迁移
方案。不能同时维护两套互相冲突的架构定义。

## 文档更新规则

1. 产品目标或模块边界改变时，先更新架构计划，再修改 RTL。
2. 新模块开工前创建设计记录；没有接口契约、正确性不变量和验证计划，不进入实现阶段。
3. 参数、端口或协议发生变化时，同一次修改必须更新父模块、断言、测试和相关文档。
4. 性能结论必须附带 Git commit、配置、命令和原始计数器数据。
5. 学习记录区分“已经由证据支持的结论”和“仍需验证的假设”。
