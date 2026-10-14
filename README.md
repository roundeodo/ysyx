# RISC-V 处理器与 SoC 集成

基于一生一芯框架开发的处理器、存储子系统和验证工具。当前 RV32 默认配置为
`rv32-balanced`：RV32I 单发射顺序执行，单级 EX，支持 Zicsr、Zifencei、
基础 M-mode 异常与定时中断；集成 BHT、BTB、RAS、早期直接目标计算及 I/D-cache。

- [文档入口](npc/docs/README.md)：配置、架构、开发规范和实验记录。
- [当前电路结构](npc/docs/microarchitecture/README.md)：模块职责、数据流与寄存边界。
- [单级 EX 验证与时序结果](npc/docs/verification/RV32_EX_MERGE_2026-10-13.md)：700 MHz 综合后 STA、面积、性能对照和复现方法。

构建、仿真和综合入口位于 `npc/Makefile` 与 `npc/scripts/`。不同历史版本的
性能结果应按各自的软件镜像、配置、延迟模型和测量边界比较。
