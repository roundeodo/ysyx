# NPC 文档中心

本目录是NPC项目的统一文档入口。RTL目录只保存源码和紧邻实现的局部注释；跨模块契约、
架构决策、开发规范、实验方法和学习记录统一放在这里。除协议字段、代码标识、命令、路径
和URL外，正文使用中文维护。

## 当前权威文档

- [RV64边缘AI处理器架构计划](architecture/ARCHITECTURE_PLAN.md)
- [AI处理器工作负载模型](architecture/AI_WORKLOAD_MODEL.md)
- [完整AXI4互连架构](interconnect/AXI4_ARCHITECTURE.md)
- [顺序流水线设计记录](microarchitecture/PIPELINE_DESIGN_RECORD.md)
- [I-cache设计记录](microarchitecture/ICACHE_DESIGN_RECORD.md)
- [D-cache设计记录](microarchitecture/DCACHE_DESIGN_RECORD.md)
- [控制流预测设计记录](microarchitecture/BRANCH_PREDICTION_DESIGN_RECORD.md)
- [cache设计空间探索方法](verification/CACHE_DESIGN_SPACE_EXPLORATION.md)
- [当前验证记录](verification/EXPERIMENT_LOG.md)
- [开发流程](development/DEVELOPMENT_PROCESS.md)
- [命名与源码组织](development/NAMING_GUIDE.md)
- [模块设计记录模板](development/MODULE_DESIGN_RECORD_TEMPLATE.md)

## 目录职责

| 目录 | 内容 |
| --- | --- |
| `architecture/` | 产品目标、工作负载和长期架构路线 |
| `microarchitecture/` | 当前模块边界、状态、协议和演进方向 |
| `interconnect/` | AXI、APB和系统互连契约 |
| `verification/` | 可复现实验方法、命令和当前证据 |
| `development/` | 命名、评审、参数化和开发流程 |
| `learning/` | 已验证经验与待验证问题 |

## 更新规则

1. 产品目标或模块边界改变时，先更新架构计划，再修改RTL。
2. 参数、端口或协议变化时，同次修改更新父模块、断言、测试和文档。
3. 性能结论必须记录commit、配置、命令、workload和原始计数器。
4. `cachesim`、`branchsim`和延迟模型用于筛选与压力测试，不能代替RTL签核。
5. 旧配置被主线替代后直接删除；不维护两套互相冲突的架构定义。
