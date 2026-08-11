// 两路组相联、阻塞式L1指令缓存顶层，hit路径采用分级流水处理。
//
// 本模块拥有lookup pipeline、way命中选择、替换策略和invalidate协调；tag/data阵列、
// miss跟踪、PMA分类和下层协议转换分别交给子模块。v1目标是hit时每周期接受一个请求、
// 固定两周期lookup延迟，并在INCR refill自然到达关键word时支持early restart。这个边界为
// 后续增加way prediction、多个MSHR、prefetch和更宽fetch保留了独立演进空间。
module riscv32_icache
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  icache_lookup_req_t  lookup_req_i,
    input  logic                lookup_req_valid_i,
    output logic                lookup_req_ready_o,
    output icache_lookup_resp_t lookup_resp_o,
    output logic                lookup_resp_valid_o,
    input  logic                lookup_resp_ready_i,

    input  logic invalidate_req_i,
    output logic invalidate_done_o,
    output logic cache_busy_o,

    // I-cache只表达“请求一组word、逐word接收响应”的本地refill语义。
    // 完整AXI4的ID、LEN、SIZE、BURST和RLAST由边界adapter负责。
    output icache_refill_req_t  refill_req_o,
    output logic                refill_req_valid_o,
    input  logic                refill_req_ready_i,
    input  icache_refill_resp_t refill_resp_i,
    input  logic                refill_resp_valid_i,
    output logic                refill_resp_ready_o,

    output icache_event_t event_o
);

  // TODO(ICACHE-TOP-1): 在本TODO正下方声明并实例化PMA、tag array、data array、
  // miss unit。AXI4 adapter位于I-cache外部的core memory边界。连接原则：
  // - lookup和refill均使用cache本地typed channel；I-cache内部不出现任何AXI类型；
  // - tag/data array的写口只能由miss unit或invalidate控制，必须有单一仲裁点；
  // - PMA分类随请求进入pipeline，不能在响应阶段重新对变化中的地址分类；
  // - 所有valid/ready独立于payload结构体。

  // TODO(ICACHE-TOP-2): 在本TODO正下方定义三段hit pipeline的寄存器。
  // S0：接受lookup并提取tag/set/word；S1：等待同步array读出；S2：比较tag并选择
  // word，持有最终hit response。每级至少保存lookup_req和PMA属性，并有独立present位：
  //
  //   icache_lookup_req_t lookup_s1_q, lookup_s2_q;
  //   pma_attr_t          memory_attr_s1_q, memory_attr_s2_q;
  //   logic               lookup_s1_present_q, lookup_s2_present_q;
  //
  // S2还保存各way tag、present和data。present位必须遵循elastic pipeline规则：下游
  // 阻塞时payload稳定；只有当前级为空或将被消费时，上一级才能推进。

  // TODO(ICACHE-TOP-3): 在本TODO正下方实现地址拆分函数或连续赋值。
  // 当前几何参数对应：offset[4:0]、set[11:5]、tag[31:12]；word index为offset[4:2]。
  // 不要硬编码这些bit位置，应由ICACHE_*_W切片生成。line base清零低
  // ICACHE_LINE_OFFSET_W位。所有地址运算使用物理地址；本项目当前没有MMU。

  // TODO(ICACHE-TOP-4): 在本TODO正下方写hit compare和way select组合逻辑。
  // 对每个way产生：line present && stored tag == request tag。结果命名为
  // `lookup_way_hit_vector`，因为它是每个way的命中集合。随后：
  // - any hit时编码出selected way index并选择对应data；
  // - executable=0时直接生成instruction access fault，不访问下层；
  // - cacheable=0时走miss unit的单word uncached流程；
  // - cacheable=1且未命中时才分配line。

  // TODO(ICACHE-TOP-5): 在本TODO正下方实现lookup pipeline的输出、next和时序更新。
  // 按编码规范保持三段式顺序：先输出逻辑，再next逻辑，最后分组always_ff。
  // hit响应从S2产生；若lookup_resp_ready_i=0，S2必须保留响应并停止S1/S0推进。
  // miss被miss unit接受后，释放S2，但blocking miss期间lookup_req_ready_o必须为0。
  // 第一版目标是hit path每周期可接收一次lookup、固定2周期hit latency；miss仍全局阻塞。
  // 标准INCR burst从line base开始；critical word对应beat自然到达时，可以在整条line
  // 填完前返回给IFU，使该条指令的后端执行与剩余refill重叠；
  // 但refill完成前仍不接收下一次lookup。这不是hit-under-miss，后者需要多个可区分的
  // 在途请求、额外MSHR以及更严格的array/refill冲突处理，应作为测量后的独立升级。

  // TODO(ICACHE-TOP-6): 在本TODO正下方实现replacement policy。
  // 每个set保存1-bit `replacement_way_index_array_q`。选择顺序必须是：先找present=0
  // 的invalid way；两个way都present时才使用replacement index。成功安装新line或命中后
  // 更新为另一个way。替换状态只影响性能，绝不能改变命中正确性。

  // TODO(ICACHE-TOP-7): 在本TODO正下方实现fence.i/invalidate状态机。
  // invalidate_req握手后停止新lookup，使用tag array现有单写口逐(set, way)把present
  // 清零，每周期处理一个way，最后脉冲invalidate_done_o。无需清data/tag内容。若未来
  // tag array增加“一拍清空整个set”的专用端口，才可把遍历粒度改为每周期一个set。
  // 当前单核无DMA一致性，fence.i是
  // 软件写代码后保证后续取指不再使用旧line的架构入口。

  // TODO(ICACHE-TOP-8): 在本TODO正下方合并event_o。
  // lookup_occurred在lookup req握手；hit_occurred在有效hit被判定；miss_occurred来自
  // miss unit；uncached_access_occurred在不可缓存请求被miss unit接受；stale response
  // 丢弃属于IFU epoch逻辑，不应在本模块凭猜测产生。

  // TODO(ICACHE-TOP-9): 完成后用定向测试检查以下功能边界：hit、miss、uncached、
  // access fault、响应反压、line refill、critical-word early restart和invalidate。
  // 测试需要同时检查hit路径不产生下层refill，以及部分填充line不会被查询命中。

endmodule
