// Simulation-only single-port AXI4-Lite memory slave. DPI is confined to this
// adapter; the CPU core and the AXI interconnect remain synthesizable.
module riscv32_sim_mem
  import riscv32_pkg::*;
#(
    parameter int unsigned IFU_READ_LATENCY   = 1,
    parameter int unsigned LSU_READ_LATENCY   = 1,
    parameter int unsigned LSU_WRITE_LATENCY  = 1,
    parameter int unsigned RANDOM_LATENCY_MAX = 20
) (
    input logic clk_i,
    input logic rst_ni,

    input  axi_lite_addr_t mem_axi_ar_i,
    input  logic           mem_axi_arvalid_i,
    output logic           mem_axi_arready_o,
    output axi_lite_r_t    mem_axi_r_o,
    output logic           mem_axi_rvalid_o,
    input  logic           mem_axi_rready_i,

    input  axi_lite_addr_t mem_axi_aw_i,
    input  logic           mem_axi_awvalid_i,
    output logic           mem_axi_awready_o,
    input  axi_lite_w_t    mem_axi_w_i,
    input  logic           mem_axi_wvalid_i,
    output logic           mem_axi_wready_o,
    output axi_lite_b_t    mem_axi_b_o,
    output logic           mem_axi_bvalid_o,
    input  logic           mem_axi_bready_i
);

  import "DPI-C" function int pmem_read(input int raddr);
  import "DPI-C" function int pmem_read_data(
    input int raddr,
    input int len
  );
  import "DPI-C" function void pmem_write(
    input int  addr,
    input int  wdata,
    input byte wmask
  );

  localparam int unsigned READ_FIXED_MAX =
      (IFU_READ_LATENCY > LSU_READ_LATENCY) ? IFU_READ_LATENCY : LSU_READ_LATENCY;
  localparam int unsigned READ_MAX_LATENCY =
      (READ_FIXED_MAX > RANDOM_LATENCY_MAX) ? READ_FIXED_MAX : RANDOM_LATENCY_MAX;
  localparam int unsigned WRITE_MAX_LATENCY =
      (LSU_WRITE_LATENCY > RANDOM_LATENCY_MAX) ? LSU_WRITE_LATENCY : RANDOM_LATENCY_MAX;
  localparam int unsigned READ_DELAY_W =
      (READ_MAX_LATENCY > 1) ? $clog2(READ_MAX_LATENCY) : 1;
  localparam int unsigned WRITE_DELAY_W =
      (WRITE_MAX_LATENCY > 1) ? $clog2(WRITE_MAX_LATENCY) : 1;

  typedef enum logic [1:0] {
    READ_IDLE,
    READ_WAIT,
    READ_RESP
  } read_state_e;

  typedef enum logic [1:0] {
    WRITE_COLLECT,
    WRITE_WAIT,
    WRITE_RESP
  } write_state_e;

  read_state_e  read_state_q;
  read_state_e  read_state_d;
  write_state_e write_state_q;
  write_state_e write_state_d;

  axi_lite_r_t read_response_q;
  axi_lite_b_t write_response_q;

  axi_lite_addr_t write_addr_q;
  axi_lite_addr_t write_addr_d;
  axi_lite_w_t    write_data_q;
  axi_lite_w_t    write_data_d;
  axi_lite_addr_t completed_write_addr;
  axi_lite_w_t    completed_write_data;

  logic [READ_DELAY_W-1:0]  read_delay_q;
  logic [READ_DELAY_W-1:0]  read_delay_d;
  logic [WRITE_DELAY_W-1:0] write_delay_q;
  logic [WRITE_DELAY_W-1:0] write_delay_d;

  logic [15:0] read_lfsr_q;
  logic [15:0] write_lfsr_q;
  logic        random_latency_enable;
  int unsigned lfsr_seed;
  int unsigned read_selected_latency;
  int unsigned write_selected_latency;

  logic write_addr_received_q;
  logic write_addr_received_d;
  logic write_data_received_q;
  logic write_data_received_d;

  logic read_addr_handshake;
  logic read_data_handshake;
  logic write_addr_handshake;
  logic write_data_handshake;
  logic write_resp_handshake;
  logic write_request_complete;

  function automatic logic [15:0] lfsr_next(input logic [15:0] value);
    lfsr_next = {value[14:0], value[15] ^ value[13] ^ value[12] ^ value[10]};
  endfunction

  function automatic int unsigned select_latency(
    input logic [15:0] value,
    input int unsigned fixed_latency
  );
    if (random_latency_enable) begin
      select_latency = 1 + (32'($unsigned(value)) % RANDOM_LATENCY_MAX);
    end else begin
      select_latency = fixed_latency;
    end
  endfunction

  always_comb begin
    read_selected_latency = select_latency(
        read_lfsr_q,
        mem_axi_ar_i.prot[2] ? IFU_READ_LATENCY : LSU_READ_LATENCY
    );
    write_selected_latency = select_latency(write_lfsr_q, LSU_WRITE_LATENCY);
  end

  assign read_addr_handshake  = mem_axi_arvalid_i && mem_axi_arready_o;
  assign read_data_handshake  = mem_axi_rvalid_o && mem_axi_rready_i;
  assign write_addr_handshake = mem_axi_awvalid_i && mem_axi_awready_o;
  assign write_data_handshake = mem_axi_wvalid_i && mem_axi_wready_o;
  assign write_resp_handshake = mem_axi_bvalid_o && mem_axi_bready_i;

  always_comb begin
    completed_write_addr = write_addr_handshake ? mem_axi_aw_i : write_addr_q;
    completed_write_data = write_data_handshake ? mem_axi_w_i : write_data_q;
    write_request_complete =
        (write_state_q == WRITE_COLLECT) &&
        (write_addr_received_q || write_addr_handshake) &&
        (write_data_received_q || write_data_handshake);
  end

  initial begin
    if (IFU_READ_LATENCY == 0) $fatal(1, "IFU_READ_LATENCY must be >= 1");
    if (LSU_READ_LATENCY == 0) $fatal(1, "LSU_READ_LATENCY must be >= 1");
    if (LSU_WRITE_LATENCY == 0) $fatal(1, "LSU_WRITE_LATENCY must be >= 1");
    if (RANDOM_LATENCY_MAX == 0) $fatal(1, "RANDOM_LATENCY_MAX must be >= 1");

    random_latency_enable = $test$plusargs("axi_random_latency");
    if (!$value$plusargs("axi_lfsr_seed=%d", lfsr_seed)) begin
      lfsr_seed = 32'h1;
    end
    if (lfsr_seed[15:0] == '0) begin
      $fatal(1, "axi_lfsr_seed must be non-zero");
    end
    if (random_latency_enable) begin
      $display("AXI sim memory random latency enabled: seed=%0d max=%0d",
               lfsr_seed, RANDOM_LATENCY_MAX);
    end
  end

  // One read transaction may be outstanding. ARPROT[2] distinguishes instruction
  // fetches from data reads for trace behavior and fixed-latency selection.
  always_comb begin
    mem_axi_arready_o = 1'b0;
    mem_axi_r_o       = read_response_q;
    mem_axi_rvalid_o  = 1'b0;

    if (rst_ni) begin
      unique case (read_state_q)
        READ_IDLE: mem_axi_arready_o = !random_latency_enable || read_lfsr_q[0];
        READ_RESP: mem_axi_rvalid_o  = 1'b1;
        default:   ;
      endcase
    end
  end

  always_comb begin
    read_state_d = read_state_q;
    read_delay_d = read_delay_q;

    unique case (read_state_q)
      READ_IDLE: begin
        if (read_addr_handshake) begin
          if (read_selected_latency == 1) begin
            read_state_d = READ_RESP;
          end else begin
            read_delay_d = READ_DELAY_W'(read_selected_latency - 1);
            read_state_d = READ_WAIT;
          end
        end
      end

      READ_WAIT: begin
        if (read_delay_q == READ_DELAY_W'(1)) begin
          read_delay_d = '0;
          read_state_d = READ_RESP;
        end else begin
          read_delay_d = read_delay_q - READ_DELAY_W'(1);
        end
      end

      READ_RESP: begin
        if (read_data_handshake) begin
          read_state_d = READ_IDLE;
        end
      end

      default: begin
        read_state_d = READ_IDLE;
        read_delay_d = '0;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_state_q    <= READ_IDLE;
      read_delay_q    <= '0;
      read_response_q <= '0;
      read_lfsr_q     <= lfsr_seed[15:0];
    end else begin
      read_state_q <= read_state_d;
      read_delay_q <= read_delay_d;

      if (random_latency_enable) begin
        read_lfsr_q <= lfsr_next(read_lfsr_q);
      end

      if (read_addr_handshake) begin
        if (mem_axi_ar_i.prot[2]) begin
          read_response_q.data <= pmem_read(int'(mem_axi_ar_i.addr));
        end else begin
          // AXI4-Lite has no AxSIZE. LSU reads one aligned word and selects the
          // requested byte or halfword after receiving RDATA.
          read_response_q.data <= pmem_read_data(int'(mem_axi_ar_i.addr), 4);
        end
        read_response_q.resp <= AXI_RESP_OKAY;
      end
    end
  end

  // AW and W are independent AXI channels and may arrive in either order. Their
  // payloads are retained until both have handshaken and exactly one write is issued.
  always_comb begin
    mem_axi_awready_o = 1'b0;
    mem_axi_wready_o  = 1'b0;
    mem_axi_b_o       = write_response_q;
    mem_axi_bvalid_o  = 1'b0;

    if (rst_ni) begin
      unique case (write_state_q)
        WRITE_COLLECT: begin
          mem_axi_awready_o = !write_addr_received_q &&
                              (!random_latency_enable || write_lfsr_q[0]);
          mem_axi_wready_o  = !write_data_received_q &&
                              (!random_latency_enable || write_lfsr_q[5]);
        end
        WRITE_RESP: mem_axi_bvalid_o = 1'b1;
        default:    ;
      endcase
    end
  end

  always_comb begin
    write_state_d         = write_state_q;
    write_delay_d         = write_delay_q;
    write_addr_d          = write_addr_q;
    write_data_d          = write_data_q;
    write_addr_received_d = write_addr_received_q;
    write_data_received_d = write_data_received_q;

    unique case (write_state_q)
      WRITE_COLLECT: begin
        if (write_addr_handshake) begin
          write_addr_d          = mem_axi_aw_i;
          write_addr_received_d = 1'b1;
        end
        if (write_data_handshake) begin
          write_data_d          = mem_axi_w_i;
          write_data_received_d = 1'b1;
        end

        if (write_request_complete) begin
          if (write_selected_latency == 1) begin
            write_state_d = WRITE_RESP;
          end else begin
            write_delay_d = WRITE_DELAY_W'(write_selected_latency - 1);
            write_state_d = WRITE_WAIT;
          end
        end
      end

      WRITE_WAIT: begin
        if (write_delay_q == WRITE_DELAY_W'(1)) begin
          write_delay_d = '0;
          write_state_d = WRITE_RESP;
        end else begin
          write_delay_d = write_delay_q - WRITE_DELAY_W'(1);
        end
      end

      WRITE_RESP: begin
        if (write_resp_handshake) begin
          write_addr_received_d = 1'b0;
          write_data_received_d = 1'b0;
          write_state_d         = WRITE_COLLECT;
        end
      end

      default: begin
        write_state_d         = WRITE_COLLECT;
        write_delay_d         = '0;
        write_addr_received_d = 1'b0;
        write_data_received_d = 1'b0;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_state_q         <= WRITE_COLLECT;
      write_delay_q         <= '0;
      write_addr_q          <= '0;
      write_data_q          <= '0;
      write_response_q      <= '0;
      write_addr_received_q <= 1'b0;
      write_data_received_q <= 1'b0;
      write_lfsr_q          <= (lfsr_seed[15:0] ^ 16'hb400) | 16'h1;
    end else begin
      write_state_q         <= write_state_d;
      write_delay_q         <= write_delay_d;
      write_addr_q          <= write_addr_d;
      write_data_q          <= write_data_d;
      write_addr_received_q <= write_addr_received_d;
      write_data_received_q <= write_data_received_d;

      if (random_latency_enable) begin
        write_lfsr_q <= lfsr_next(write_lfsr_q);
      end

      if (write_request_complete) begin
        pmem_write(
            int'(completed_write_addr.addr),
            int'(completed_write_data.data),
            byte'(completed_write_data.strb)
        );
        write_response_q.resp <= AXI_RESP_OKAY;
      end
    end
  end

  // The read and write AXI channels can complete concurrently. Same-address,
  // same-cycle read/write behavior is intentionally backend-defined at this phase.

  p_mem_arprot_known :
  assert property (@(posedge clk_i) read_addr_handshake |-> !$isunknown(mem_axi_ar_i.prot))
  else $error("Memory ARPROT contains X at handshake");

  p_mem_awprot_known :
  assert property (@(posedge clk_i) write_addr_handshake |-> !$isunknown(mem_axi_aw_i.prot))
  else $error("Memory AWPROT contains X at handshake");

  p_completed_awprot_known :
  assert property (
    @(posedge clk_i) write_request_complete |-> !$isunknown(completed_write_addr.prot)
  )
  else $error("Stored memory AWPROT contains X when write request completes");

  p_read_response_stable_while_stalled :
  assert property (
    @(posedge clk_i)
      mem_axi_rvalid_o && !mem_axi_rready_i
      |=> mem_axi_rvalid_o && $stable(mem_axi_r_o)
  ) else $error("Memory R channel changed while stalled");

  p_write_response_stable_while_stalled :
  assert property (
    @(posedge clk_i)
      mem_axi_bvalid_o && !mem_axi_bready_i
      |=> mem_axi_bvalid_o && $stable(mem_axi_b_o)
  ) else $error("Memory B channel changed while stalled");

  p_read_response_requires_request :
  assert property (
    @(posedge clk_i)
      mem_axi_rvalid_o |-> read_state_q == READ_RESP
  ) else $error("Memory RVALID asserted without a completed AR request");

  p_write_response_requires_request :
  assert property (
    @(posedge clk_i)
      mem_axi_bvalid_o |-> write_state_q == WRITE_RESP
  ) else $error("Memory BVALID asserted without completed AW and W requests");

  p_write_address_not_accepted_twice :
  assert property (
    @(posedge clk_i)
      write_addr_received_q |-> !mem_axi_awready_o
  ) else $error("Memory accepted a second AW for one write transaction");

  p_write_data_not_accepted_twice :
  assert property (
    @(posedge clk_i)
      write_data_received_q |-> !mem_axi_wready_o
  ) else $error("Memory accepted a second W for one write transaction");

endmodule
