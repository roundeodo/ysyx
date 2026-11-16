module sdram (
    input        clk,
    input        cke,
    input        cs,
    input        ras,
    input        cas,
    input        we,
    input [12:0] a,
    input [ 1:0] ba,
    input [ 3:0] dqm,
    inout [31:0] dq
);

  localparam [3:0] SDRAM_CMD_LOAD_MODE = 4'b0000;
  localparam [3:0] SDRAM_CMD_AUTO_REFRESH = 4'b0001;
  localparam [3:0] SDRAM_CMD_PRECHARGE = 4'b0010;
  localparam [3:0] SDRAM_CMD_ACTIVATE = 4'b0011;
  localparam [3:0] SDRAM_CMD_WRITE = 4'b0100;
  localparam [3:0] SDRAM_CMD_READ = 4'b0101;
  localparam [3:0] SDRAM_CMD_BURST_TERMINATE = 4'b0110;
  localparam [3:0] SDRAM_CMD_NOP = 4'b0111;

  localparam [1:0] READ_STATE_IDLE = 2'd0;
  localparam [1:0] READ_STATE_WAIT_LATENCY = 2'd1;
  localparam [1:0] READ_STATE_RETURN_DATA = 2'd2;

  localparam WRITE_STATE_IDLE         = 1'b0;
  localparam WRITE_STATE_RECEIVE_DATA = 1'b1;

  localparam integer SDRAM_BANK_COUNT = 4;
  localparam integer SDRAM_ROW_COUNT = 8192;
  localparam integer SDRAM_COLUMN_COUNT = 512;
  localparam integer SDRAM_WORD_COUNT = SDRAM_BANK_COUNT * SDRAM_ROW_COUNT * SDRAM_COLUMN_COUNT;

  // 两个并行x16颗粒在相同Bank/Row/Column上共同形成一个32-bit存储字。
  reg  [31:0] memory_word_array                  [0:SDRAM_WORD_COUNT-1];

  wire [ 3:0] sdram_command = {cs, ras, cas, we};

  // LOAD MODE写入的运行时配置。
  reg  [ 9:0] configured_burst_beat_count_q;
  reg  [ 9:0] configured_burst_beat_count_d;
  reg  [ 3:0] configured_cas_latency_q;
  reg  [ 3:0] configured_cas_latency_d;
  reg         configured_write_single_beat_q;
  reg         configured_write_single_beat_d;

  // 每个Bank当前打开的Row。
  reg  [ 3:0] active_row_present_vector_q;
  reg  [ 3:0] active_row_present_vector_d;
  reg  [12:0] active_row_index_array_q           [0:SDRAM_BANK_COUNT-1];
  reg  [12:0] active_row_index_array_d           [0:SDRAM_BANK_COUNT-1];

  // READ事务状态。
  reg  [ 1:0] read_state_q;
  reg  [ 1:0] read_state_d;
  reg  [ 3:0] read_latency_cycle_count_q;
  reg  [ 3:0] read_latency_cycle_count_d;
  reg  [ 1:0] read_bank_index_q;
  reg  [ 1:0] read_bank_index_d;
  reg  [12:0] read_row_index_q;
  reg  [12:0] read_row_index_d;
  reg  [ 8:0] read_start_column_index_q;
  reg  [ 8:0] read_start_column_index_d;
  reg  [ 9:0] read_burst_beat_count_q;
  reg  [ 9:0] read_burst_beat_count_d;
  reg  [ 8:0] read_beat_index_q;
  reg  [ 8:0] read_beat_index_d;
  reg         read_auto_precharge_q;
  reg         read_auto_precharge_d;

  // WRITE事务状态。
  reg         write_state_q;
  reg         write_state_d;
  reg  [ 1:0] write_bank_index_q;
  reg  [ 1:0] write_bank_index_d;
  reg  [12:0] write_row_index_q;
  reg  [12:0] write_row_index_d;
  reg  [ 8:0] write_start_column_index_q;
  reg  [ 8:0] write_start_column_index_d;
  reg  [ 9:0] write_burst_beat_count_q;
  reg  [ 9:0] write_burst_beat_count_d;
  reg  [ 8:0] write_beat_index_q;
  reg  [ 8:0] write_beat_index_d;
  reg         write_auto_precharge_q;
  reg         write_auto_precharge_d;

  // READ输出控制。
  reg  [31:0] read_data_output;
  reg         read_data_drive_present;

  // WRITE对内部存储阵列的写控制。
  reg  [ 3:0] memory_write_byte_enable_vector;
  reg  [23:0] memory_write_word_index;
  reg  [31:0] memory_write_data;

  // --------------------------------------------------------------------------
  // LOAD MODE配置
  // --------------------------------------------------------------------------

  // 将Mode Register中的Burst Length编码转换为实际beat数。
  function [9:0] mode_to_burst_beat_count;
    input [2:0] burst_length_mode;
    begin
      case (burst_length_mode)
        3'b000:  mode_to_burst_beat_count = 10'd1;
        3'b001:  mode_to_burst_beat_count = 10'd2;
        3'b010:  mode_to_burst_beat_count = 10'd4;
        3'b011:  mode_to_burst_beat_count = 10'd8;
        3'b111:  mode_to_burst_beat_count = 10'd512;
        default: mode_to_burst_beat_count = 10'd1;
      endcase
    end
  endfunction

  // 下一配置状态。
  always @(*) begin
    configured_burst_beat_count_d  = configured_burst_beat_count_q;
    configured_cas_latency_d       = configured_cas_latency_q;
    configured_write_single_beat_d = configured_write_single_beat_q;

    if (cke && sdram_command == SDRAM_CMD_LOAD_MODE) begin
      configured_burst_beat_count_d  = mode_to_burst_beat_count(a[2:0]);
      configured_cas_latency_d       = {1'b0, a[6:4]};
      configured_write_single_beat_d = a[9];
    end
  end

  // 配置寄存器更新。
  initial begin
    configured_burst_beat_count_q  = 10'd1;
    configured_cas_latency_q       = 4'd2;
    configured_write_single_beat_q = 1'b0;
  end

  always @(posedge clk) begin
    configured_burst_beat_count_q  <= configured_burst_beat_count_d;
    configured_cas_latency_q       <= configured_cas_latency_d;
    configured_write_single_beat_q <= configured_write_single_beat_d;

    if (cke && sdram_command == SDRAM_CMD_LOAD_MODE) begin
      if (a[3] != 1'b0) $error("SDRAM model does not support interleaved bursts");

      if (a[6:4] < 3'd1 || a[6:4] > 3'd3) $error("Unsupported SDRAM CAS latency: %0d", a[6:4]);
    end
  end

  // --------------------------------------------------------------------------
  // Bank活动行状态
  // --------------------------------------------------------------------------

  // Bank状态块消费的事务完成事件，用于处理自动预充电。
  wire read_last_beat_output_occurred =
      cke && (read_state_q == READ_STATE_RETURN_DATA) &&
      (read_beat_index_q + 10'd1 >= read_burst_beat_count_q);

  wire write_last_beat_input_occurred =
      cke && (write_state_q == WRITE_STATE_RECEIVE_DATA) &&
      (sdram_command != SDRAM_CMD_BURST_TERMINATE) &&
      (write_beat_index_q + 10'd1 >= write_burst_beat_count_q);

  wire write_command_single_beat =
      configured_write_single_beat_q || (configured_burst_beat_count_q == 10'd1);

  integer bank_index;

  // 下一Bank状态。命令处理的优先级高于事务结束引起的自动预充电。
  always @(*) begin
    active_row_present_vector_d = active_row_present_vector_q;

    for (bank_index = 0; bank_index < SDRAM_BANK_COUNT; bank_index = bank_index + 1) begin
      active_row_index_array_d[bank_index] = active_row_index_array_q[bank_index];
    end

    if (cke) begin
      if (read_last_beat_output_occurred && read_auto_precharge_q)
        active_row_present_vector_d[read_bank_index_q] = 1'b0;

      if (write_last_beat_input_occurred && write_auto_precharge_q)
        active_row_present_vector_d[write_bank_index_q] = 1'b0;

      case (sdram_command)
        SDRAM_CMD_ACTIVATE: begin
          active_row_present_vector_d[ba] = 1'b1;
          active_row_index_array_d[ba]    = a;
        end

        SDRAM_CMD_PRECHARGE: begin
          // A10=1表示关闭所有Bank，否则只关闭BA选中的Bank。
          if (a[10]) active_row_present_vector_d = 4'b0000;
          else active_row_present_vector_d[ba] = 1'b0;
        end

        SDRAM_CMD_WRITE: begin
          if (a[10] && write_command_single_beat) active_row_present_vector_d[ba] = 1'b0;
        end

        // 行为模型不模拟刷新带来的电气保持特性。
        SDRAM_CMD_AUTO_REFRESH, SDRAM_CMD_NOP: begin
        end

        default: begin
        end
      endcase
    end
  end

  // Bank状态寄存器更新。
  initial begin
    active_row_present_vector_q = 4'b0000;

    for (bank_index = 0; bank_index < SDRAM_BANK_COUNT; bank_index = bank_index + 1) begin
      active_row_index_array_q[bank_index] = 13'd0;
    end
  end

  always @(posedge clk) begin
    active_row_present_vector_q <= active_row_present_vector_d;

    for (bank_index = 0; bank_index < SDRAM_BANK_COUNT; bank_index = bank_index + 1) begin
      active_row_index_array_q[bank_index] <= active_row_index_array_d[bank_index];
    end
  end

  // --------------------------------------------------------------------------
  // READ/WRITE共享的Burst地址计算
  // --------------------------------------------------------------------------

  // 这两个函数只服务于紧随其后的READ和WRITE状态机。
  // READ和WRITE共享的Burst列地址计算。
  // SDRAM顺序突发只能在当前突发边界内循环。
  function [8:0] select_burst_column_index;
    input [8:0] start_column_index;
    input [8:0] beat_index;
    input [9:0] burst_beat_count;

    reg [8:0] incremented_column_index;

    begin
      incremented_column_index = start_column_index + beat_index;

      case (burst_beat_count)
        10'd1: select_burst_column_index = start_column_index;

        10'd2: select_burst_column_index = {start_column_index[8:1], incremented_column_index[0]};

        10'd4: select_burst_column_index = {start_column_index[8:2], incremented_column_index[1:0]};

        10'd8: select_burst_column_index = {start_column_index[8:3], incremented_column_index[2:0]};

        10'd512: select_burst_column_index = incremented_column_index;

        default: select_burst_column_index = start_column_index;
      endcase
    end
  endfunction

  // 并行颗粒形成的一个32-bit Word由Bank、Row和Column共同定位。
  function [23:0] compose_memory_word_index;
    input [1:0] selected_bank_index;
    input [12:0] row_index;
    input [8:0] column_index;

    begin
      compose_memory_word_index = {selected_bank_index, row_index, column_index};
    end
  endfunction

  // --------------------------------------------------------------------------
  // READ三段式状态机
  // --------------------------------------------------------------------------

  // READ返回当前beat时需要访问的列和存储数组索引。
  wire [8:0] current_read_column_index = select_burst_column_index(
      read_start_column_index_q, read_beat_index_q, read_burst_beat_count_q
  );

  wire [23:0] current_read_memory_word_index = compose_memory_word_index(
      read_bank_index_q, read_row_index_q, current_read_column_index
  );

  // 第一段：READ状态机输出。只有RETURN_DATA状态驱动DQ。
  always @(*) begin
    read_data_output        = 32'd0;
    read_data_drive_present = 1'b0;

    if (read_state_q == READ_STATE_RETURN_DATA) begin
      read_data_output        = memory_word_array[current_read_memory_word_index];
      read_data_drive_present = 1'b1;
    end
  end

  assign dq = read_data_drive_present ? read_data_output : 32'hzzzz_zzzz;

  // 第二段：READ状态转移与事务信息的下一值。
  always @(*) begin
    read_state_d               = read_state_q;
    read_latency_cycle_count_d = read_latency_cycle_count_q;
    read_bank_index_d          = read_bank_index_q;
    read_row_index_d           = read_row_index_q;
    read_start_column_index_d  = read_start_column_index_q;
    read_burst_beat_count_d    = read_burst_beat_count_q;
    read_beat_index_d          = read_beat_index_q;
    read_auto_precharge_d      = read_auto_precharge_q;

    if (cke) begin
      case (read_state_q)
        READ_STATE_IDLE: begin
          if (sdram_command == SDRAM_CMD_READ) begin
            read_state_d               = READ_STATE_WAIT_LATENCY;
            // 接收READ命令的时钟沿计入CAS latency。
            read_latency_cycle_count_d = configured_cas_latency_q - 4'd1;
            read_bank_index_d          = ba;
            read_row_index_d           = active_row_index_array_q[ba];
            read_start_column_index_d  = a[8:0];
            read_burst_beat_count_d    = configured_burst_beat_count_q;
            read_beat_index_d          = 9'd0;
            read_auto_precharge_d      = a[10];
          end
        end

        READ_STATE_WAIT_LATENCY: begin
          if (sdram_command == SDRAM_CMD_BURST_TERMINATE) begin
            read_state_d      = READ_STATE_IDLE;
            read_beat_index_d = 9'd0;
          end else if (read_latency_cycle_count_q > 4'd1) begin
            read_latency_cycle_count_d = read_latency_cycle_count_q - 4'd1;
          end else begin
            read_state_d = READ_STATE_RETURN_DATA;
          end
        end

        READ_STATE_RETURN_DATA: begin
          if (sdram_command == SDRAM_CMD_BURST_TERMINATE) begin
            read_state_d      = READ_STATE_IDLE;
            read_beat_index_d = 9'd0;
          end else if (read_last_beat_output_occurred && sdram_command == SDRAM_CMD_READ) begin
            // 当前读事务最后一个beat正在DQ上返回时，控制器可以同时发送下一条
            // READ命令。旧数据仍由本周期的q寄存器驱动；这里仅锁存下一事务，
            // 避免因为先回到IDLE而丢失已经到达的流水化READ命令。
            read_state_d               = READ_STATE_WAIT_LATENCY;
            read_latency_cycle_count_d = configured_cas_latency_q - 4'd1;
            read_bank_index_d          = ba;
            read_row_index_d           = active_row_index_array_q[ba];
            read_start_column_index_d  = a[8:0];
            read_burst_beat_count_d    = configured_burst_beat_count_q;
            read_beat_index_d          = 9'd0;
            read_auto_precharge_d      = a[10];
          end else if (read_last_beat_output_occurred) begin
            read_state_d      = READ_STATE_IDLE;
            read_beat_index_d = 9'd0;
          end else begin
            read_beat_index_d = read_beat_index_q + 9'd1;
          end
        end

        default: begin
          read_state_d      = READ_STATE_IDLE;
          read_beat_index_d = 9'd0;
        end
      endcase
    end
  end

  // 第三段：READ状态和事务寄存器更新。
  initial begin
    read_state_q               = READ_STATE_IDLE;
    read_latency_cycle_count_q = 4'd0;
    read_bank_index_q          = 2'd0;
    read_row_index_q           = 13'd0;
    read_start_column_index_q  = 9'd0;
    read_burst_beat_count_q    = 10'd1;
    read_beat_index_q          = 9'd0;
    read_auto_precharge_q      = 1'b0;
  end

  always @(posedge clk) begin
    read_state_q               <= read_state_d;
    read_latency_cycle_count_q <= read_latency_cycle_count_d;
    read_bank_index_q          <= read_bank_index_d;
    read_row_index_q           <= read_row_index_d;
    read_start_column_index_q  <= read_start_column_index_d;
    read_burst_beat_count_q    <= read_burst_beat_count_d;
    read_beat_index_q          <= read_beat_index_d;
    read_auto_precharge_q      <= read_auto_precharge_d;

    if (cke && sdram_command == SDRAM_CMD_READ && !active_row_present_vector_q[ba])
      $error("SDRAM READ without active row, bank=%0d", ba);
  end

  // --------------------------------------------------------------------------
  // WRITE三段式状态机
  // --------------------------------------------------------------------------

  // WRITE当前beat和WRITE命令首beat对应的存储数组索引。
  wire [8:0] current_write_column_index = select_burst_column_index(
      write_start_column_index_q, write_beat_index_q, write_burst_beat_count_q
  );

  wire [23:0] current_write_memory_word_index = compose_memory_word_index(
      write_bank_index_q, write_row_index_q, current_write_column_index
  );

  wire [23:0] write_command_memory_word_index = compose_memory_word_index(
      ba, active_row_index_array_q[ba], a[8:0]
  );

  // 第一段：WRITE状态机输出，产生存储阵列的写端口控制。
  always @(*) begin
    memory_write_byte_enable_vector = 4'b0000;
    memory_write_word_index         = 24'd0;
    memory_write_data               = dq;

    if (cke) begin
      if (write_state_q == WRITE_STATE_IDLE && sdram_command == SDRAM_CMD_WRITE) begin
        memory_write_byte_enable_vector = ~dqm;
        memory_write_word_index         = write_command_memory_word_index;
      end else if (write_state_q == WRITE_STATE_RECEIVE_DATA &&
                   sdram_command != SDRAM_CMD_BURST_TERMINATE) begin
        memory_write_byte_enable_vector = ~dqm;
        memory_write_word_index         = current_write_memory_word_index;
      end
    end
  end

  // 第二段：WRITE状态转移与事务信息的下一值。
  always @(*) begin
    write_state_d              = write_state_q;
    write_bank_index_d         = write_bank_index_q;
    write_row_index_d          = write_row_index_q;
    write_start_column_index_d = write_start_column_index_q;
    write_burst_beat_count_d   = write_burst_beat_count_q;
    write_beat_index_d         = write_beat_index_q;
    write_auto_precharge_d     = write_auto_precharge_q;

    if (cke) begin
      case (write_state_q)
        WRITE_STATE_IDLE: begin
          if (sdram_command == SDRAM_CMD_WRITE) begin
            write_bank_index_d         = ba;
            write_row_index_d          = active_row_index_array_q[ba];
            write_start_column_index_d = a[8:0];
            write_burst_beat_count_d   = write_command_single_beat
                                         ? 10'd1
                                         : configured_burst_beat_count_q;
            // 第0个beat由WRITE命令周期直接写入。
            write_beat_index_d     = 9'd1;
            write_auto_precharge_d = a[10];
            write_state_d          = write_command_single_beat ? WRITE_STATE_IDLE : WRITE_STATE_RECEIVE_DATA;
          end
        end

        WRITE_STATE_RECEIVE_DATA: begin
          if (sdram_command == SDRAM_CMD_BURST_TERMINATE || write_last_beat_input_occurred) begin
            write_state_d      = WRITE_STATE_IDLE;
            write_beat_index_d = 9'd0;
          end else begin
            write_beat_index_d = write_beat_index_q + 9'd1;
          end
        end

        default: begin
          write_state_d      = WRITE_STATE_IDLE;
          write_beat_index_d = 9'd0;
        end
      endcase
    end
  end

  // 第三段：WRITE状态寄存器更新，并在有效写节拍更新存储阵列。
  initial begin
    write_state_q              = WRITE_STATE_IDLE;
    write_bank_index_q         = 2'd0;
    write_row_index_q          = 13'd0;
    write_start_column_index_q = 9'd0;
    write_burst_beat_count_q   = 10'd1;
    write_beat_index_q         = 9'd0;
    write_auto_precharge_q     = 1'b0;
  end

  always @(posedge clk) begin
    write_state_q              <= write_state_d;
    write_bank_index_q         <= write_bank_index_d;
    write_row_index_q          <= write_row_index_d;
    write_start_column_index_q <= write_start_column_index_d;
    write_burst_beat_count_q   <= write_burst_beat_count_d;
    write_beat_index_q         <= write_beat_index_d;
    write_auto_precharge_q     <= write_auto_precharge_d;

    if (memory_write_byte_enable_vector[0])
      memory_word_array[memory_write_word_index][7:0] <= memory_write_data[7:0];

    if (memory_write_byte_enable_vector[1])
      memory_word_array[memory_write_word_index][15:8] <= memory_write_data[15:8];

    if (memory_write_byte_enable_vector[2])
      memory_word_array[memory_write_word_index][23:16] <= memory_write_data[23:16];

    if (memory_write_byte_enable_vector[3])
      memory_word_array[memory_write_word_index][31:24] <= memory_write_data[31:24];

    if (cke && sdram_command == SDRAM_CMD_WRITE && !active_row_present_vector_q[ba])
      $error("SDRAM WRITE without active row, bank=%0d", ba);
  end

endmodule
