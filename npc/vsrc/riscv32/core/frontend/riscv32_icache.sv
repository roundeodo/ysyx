// Two-way blocking L1 instruction cache with a pipelined hit path.
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

    output axi_lite_addr_t lower_axi_ar_o,
    output logic           lower_axi_arvalid_o,
    input  logic           lower_axi_arready_i,
    input  axi_lite_r_t    lower_axi_r_i,
    input  logic           lower_axi_rvalid_i,
    output logic           lower_axi_rready_o,

    output icache_event_t event_o
);

  // TODO(ICACHE-TOP-1): 在本TODO正下方声明并实例化PMA、tag array、data array、
  // miss unit和refill adapter。连接原则：
  // - lookup只使用cache本地typed channel；只有refill adapter看见AXI4-Lite；
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
  // - $onehot0断言最多一个way命中；
  // - any hit时编码出selected way index并选择对应data；
  // - executable=0时直接生成instruction access fault，不访问下层；
  // - cacheable=0时走miss unit的单word uncached流程；
  // - cacheable=1且未命中时才分配line。

  // TODO(ICACHE-TOP-5): 在本TODO正下方实现lookup pipeline的输出、next和时序更新。
  // 按编码规范保持三段式顺序：先输出逻辑，再next逻辑，最后分组always_ff。
  // hit响应从S2产生；若lookup_resp_ready_i=0，S2必须保留响应并停止S1/S0推进。
  // miss被miss unit接受后，释放S2，但blocking miss期间lookup_req_ready_o必须为0。
  // 第一版目标是hit path每周期可接收一次lookup、固定2周期hit latency；miss仍全局阻塞。
  // critical word可以在整条line填完前返回给IFU，使该条指令的后端执行与剩余refill重叠；
  // 但refill完成前仍不接收下一次lookup。这不是hit-under-miss，后者需要多个可区分的
  // 在途请求、额外MSHR以及更严格的array/refill冲突处理，应作为测量后的独立升级。

  // TODO(ICACHE-TOP-6): 在本TODO正下方实现replacement policy。
  // 每个set保存1-bit `replacement_way_index_array_q`。选择顺序必须是：先找present=0
  // 的invalid way；两个way都present时才使用replacement index。成功安装新line或命中后
  // 更新为另一个way。替换状态只影响性能，绝不能改变命中正确性。

  // TODO(ICACHE-TOP-7): 在本TODO正下方实现fence.i/invalidate状态机。
  // invalidate_req握手后停止新lookup，逐set把两个way的present清零，每周期处理一个set，
  // 最后脉冲invalidate_done_o。无需清data/tag内容。当前单核无DMA一致性，fence.i是
  // 软件写代码后保证后续取指不再使用旧line的架构入口。

  // TODO(ICACHE-TOP-8): 在本TODO正下方合并event_o。
  // lookup_occurred在lookup req握手；hit_occurred在有效hit被判定；miss_occurred来自
  // miss unit；uncached_access_occurred在不可缓存请求被miss unit接受；stale response
  // 丢弃属于IFU epoch逻辑，不应在本模块凭猜测产生。

  // TODO(ICACHE-TOP-9): 加入模块断言和性能检查。
  // - lookup response在反压期间稳定；
  // - hit/miss/uncached/fault分类互斥且覆盖每个被处理lookup；
  // - line present只由完整refill或invalidate更新；
  // - miss期间不接受新lookup；
  // - non-executable地址不产生AXI请求；
  // - hit regression不产生任何lower AXI流量。

endmodule
