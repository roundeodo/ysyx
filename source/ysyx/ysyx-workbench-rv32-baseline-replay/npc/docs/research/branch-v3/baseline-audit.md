# 基线源码核验

CPU来自fbe7824，加上已验证的新设备模型移植；当前工作树存在移植修改，并非干净的历史commit。
branch_predictor并行查BTB/BHT/RAS，只有一个预测响应寄存级；IFU两项请求队列有空时直通。
条件方向即使正确，也必须BTB给出类型和目标才可能采用taken；RAS也受BTB return识别门控。
BHT0为16项二位计数器，无历史；旧policy3/4为三表缩小TAGE，不含SC/loop。历史在已解析训练事件更新。
查询快照随branch_prediction传递；EX结果交付训练，不是提交训练。invalidate与flush的作用不同。
已有FENCE.I错误taken纠正、维护失败停止、dirty-victim恢复必须保留。预测器模块功能通过不等于训练快照整核接线通过。

独立测试台trace只有pc/instruction/next_pc/cycle，不能单靠next_pc推断branch target=PC+4时的taken；V3新驱动必须拒绝这种含糊数据或从执行信号记录真值。
旧测试台query_by_tag不是全局唯一动态ID；扩展观察器时需增加单调64位ID。
旧研究文档仍有完整结果但部分原始产物已删除，因此旧PPA仅为历史，不能假装本轮重测。
新模型移植已有MicroBench test Total2774833周期、Scored1088342周期、观察器开关一致的报告；V3候选必须另做闭环。
