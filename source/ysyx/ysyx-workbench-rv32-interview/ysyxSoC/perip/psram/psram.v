module psram (
    input       sck,
    input       ce_n,
    inout [3:0] dio
);

  localparam integer PSRAM_BYTE_COUNT = 4 * 1024 * 1024;

  localparam [7:0] PSRAM_COMMAND_QUAD_IO_READ  = 8'hEB;
  localparam [7:0] PSRAM_COMMAND_QUAD_IO_WRITE = 8'h38;
  localparam [7:0] PSRAM_COMMAND_ENTER_QPI     = 8'h35;
  localparam [7:0] PSRAM_COMMAND_EXIT_QPI      = 8'hF5;

  localparam PSRAM_INTERFACE_MODE_SPI = 1'b0;
  localparam PSRAM_INTERFACE_MODE_QPI = 1'b1;

  localparam [2:0] TRANSACTION_STATE_RECEIVE_COMMAND            = 3'd0;
  localparam [2:0] TRANSACTION_STATE_RECEIVE_ADDRESS            = 3'd1;
  localparam [2:0] TRANSACTION_STATE_WAIT_READ_DUMMY_CYCLES     = 3'd2;
  localparam [2:0] TRANSACTION_STATE_SEND_READ_DATA             = 3'd3;
  localparam [2:0] TRANSACTION_STATE_RECEIVE_WRITE_DATA         = 3'd4;
  localparam [2:0] TRANSACTION_STATE_IGNORE_UNSUPPORTED_COMMAND = 3'd5;

  localparam NIBBLE_POSITION_UPPER = 1'b0;
  localparam NIBBLE_POSITION_LOWER = 1'b1;

  // byte-addressed PSRAM storage array
  reg  [ 7:0] psram_byte_array [0:PSRAM_BYTE_COUNT - 1];

  reg  [ 2:0] transaction_state_q;

  reg  [ 6:0] received_command_prefix_q;
  reg  [ 7:0] transaction_command_q;
  reg  [ 2:0] command_bit_index_q;
  reg         command_nibble_position_q;
  reg         interface_mode_q;

  reg  [19:0] received_address_prefix_q;
  reg  [ 2:0] address_nibble_index_q;
  reg  [23:0] transaction_byte_addr_q;

  reg  [ 2:0] read_dummy_cycle_index_q;
  reg         read_data_nibble_position_q;
  reg         write_data_nibble_position_q;
  reg  [ 3:0] write_byte_upper_nibble_q;

  reg  [ 3:0] dio_output_nibble_q;
  reg         dio_output_enable_q;

  wire [ 3:0] dio_input_nibble;

  assign dio_input_nibble = dio;

  // Only the PSRAM read-data phase drives DIO.
  // All command, address and write phases are driven by the controller.
  assign dio = dio_output_enable_q ? dio_output_nibble_q : 4'bz;

  // This is a simulation model, so an initial block is acceptable.
  // The memory array itself is intentionally not initialized.

  initial begin
    transaction_state_q = TRANSACTION_STATE_RECEIVE_COMMAND;

    received_command_prefix_q = 7'b0;
    transaction_command_q     = 8'b0;
    command_bit_index_q       = 3'b0;
    command_nibble_position_q = NIBBLE_POSITION_UPPER;
    interface_mode_q          = PSRAM_INTERFACE_MODE_SPI;

    received_address_prefix_q = 20'b0;
    address_nibble_index_q     = 3'b0;
    transaction_byte_addr_q    = 24'b0;

    read_dummy_cycle_index_q      = 3'b0;
    read_data_nibble_position_q   = NIBBLE_POSITION_UPPER;
    write_data_nibble_position_q  = NIBBLE_POSITION_UPPER;
    write_byte_upper_nibble_q     = 4'b0;

    dio_output_nibble_q = 4'b0;
    dio_output_enable_q = 1'b0;
  end

  // The controller changes its QSPI output around the falling edge.
  // The PSRAM therefore samples command/address/write data at posedge sck.
  //
  // During reads, this model also updates DIO at posedge sck.
  // The controller samples the returned data at the following falling edge.
  //
  // ce_n rising terminates the current transaction and releases DIO.
  always @(posedge sck or posedge ce_n) begin
    if (ce_n) begin
      transaction_state_q <= TRANSACTION_STATE_RECEIVE_COMMAND;

      received_command_prefix_q <= 7'b0;
      transaction_command_q     <= 8'b0;
      command_bit_index_q       <= 3'b0;
      command_nibble_position_q <= NIBBLE_POSITION_UPPER;

      received_address_prefix_q <= 20'b0;
      address_nibble_index_q     <= 3'b0;
      transaction_byte_addr_q    <= 24'b0;

      read_dummy_cycle_index_q     <= 3'b0;
      read_data_nibble_position_q  <= NIBBLE_POSITION_UPPER;
      write_data_nibble_position_q <= NIBBLE_POSITION_UPPER;
      write_byte_upper_nibble_q    <= 4'b0;

      dio_output_nibble_q <= 4'b0;
      dio_output_enable_q <= 1'b0;
    end else begin
      case (transaction_state_q)

        // The device powers up in SPI mode, where commands arrive serially on
        // DIO0. After 35h, QPI commands arrive as two four-bit transfers.
        TRANSACTION_STATE_RECEIVE_COMMAND: begin
          dio_output_enable_q <= 1'b0;

          if (interface_mode_q == PSRAM_INTERFACE_MODE_SPI) begin
            received_command_prefix_q <= {
              received_command_prefix_q[5:0],
              dio_input_nibble[0]
            };

            if (command_bit_index_q == 3'd7) begin
              transaction_command_q <= {
                received_command_prefix_q,
                dio_input_nibble[0]
              };

              command_bit_index_q <= 3'b0;

              case ({received_command_prefix_q, dio_input_nibble[0]})
                PSRAM_COMMAND_ENTER_QPI: begin
                  interface_mode_q    <= PSRAM_INTERFACE_MODE_QPI;
                  transaction_state_q <= TRANSACTION_STATE_IGNORE_UNSUPPORTED_COMMAND;
                end

                PSRAM_COMMAND_QUAD_IO_READ,
                PSRAM_COMMAND_QUAD_IO_WRITE: begin
                  received_address_prefix_q <= 20'b0;
                  address_nibble_index_q    <= 3'b0;
                  transaction_state_q       <= TRANSACTION_STATE_RECEIVE_ADDRESS;
                end

                default:
                  transaction_state_q <= TRANSACTION_STATE_IGNORE_UNSUPPORTED_COMMAND;
              endcase
            end else begin
              command_bit_index_q <= command_bit_index_q + 3'd1;
            end
          end else begin
            if (command_nibble_position_q == NIBBLE_POSITION_UPPER) begin
              transaction_command_q[7:4] <= dio_input_nibble;
              command_nibble_position_q  <= NIBBLE_POSITION_LOWER;
            end else begin
              transaction_command_q[3:0] <= dio_input_nibble;
              command_nibble_position_q  <= NIBBLE_POSITION_UPPER;

              case ({transaction_command_q[7:4], dio_input_nibble})
                PSRAM_COMMAND_QUAD_IO_READ,
                PSRAM_COMMAND_QUAD_IO_WRITE: begin
                  received_address_prefix_q <= 20'b0;
                  address_nibble_index_q    <= 3'b0;
                  transaction_state_q       <= TRANSACTION_STATE_RECEIVE_ADDRESS;
                end

                PSRAM_COMMAND_EXIT_QPI: begin
                  interface_mode_q    <= PSRAM_INTERFACE_MODE_SPI;
                  transaction_state_q <= TRANSACTION_STATE_IGNORE_UNSUPPORTED_COMMAND;
                end

                default:
                  transaction_state_q <= TRANSACTION_STATE_IGNORE_UNSUPPORTED_COMMAND;
              endcase
            end
          end
        end

        // The 24-bit address is transferred through all four DIO lines.
        // Six QSPI cycles are needed: 24 / 4 = 6.
        TRANSACTION_STATE_RECEIVE_ADDRESS: begin
          dio_output_enable_q <= 1'b0;

          received_address_prefix_q <= {
            received_address_prefix_q[15:0],
            dio_input_nibble
          };

          if (address_nibble_index_q == 3'd5) begin
            transaction_byte_addr_q <= {
              received_address_prefix_q,
              dio_input_nibble
            };

            address_nibble_index_q <= 3'b0;

            if (transaction_command_q == PSRAM_COMMAND_QUAD_IO_READ) begin
              read_dummy_cycle_index_q    <= 3'b0;
              read_data_nibble_position_q <= NIBBLE_POSITION_UPPER;
              transaction_state_q         <= TRANSACTION_STATE_WAIT_READ_DUMMY_CYCLES;
            end else begin
              write_data_nibble_position_q <= NIBBLE_POSITION_UPPER;
              transaction_state_q           <= TRANSACTION_STATE_RECEIVE_WRITE_DATA;
            end
          end else begin
            address_nibble_index_q <= address_nibble_index_q + 3'd1;
          end
        end

        // The EBh command used by the existing controller contains
        // six dummy SCK cycles between address and read data.
        TRANSACTION_STATE_WAIT_READ_DUMMY_CYCLES: begin
          dio_output_enable_q <= 1'b0;

          if (read_dummy_cycle_index_q == 3'd5) begin
            read_dummy_cycle_index_q    <= 3'b0;
            read_data_nibble_position_q <= NIBBLE_POSITION_UPPER;
            transaction_state_q         <= TRANSACTION_STATE_SEND_READ_DATA;
          end else begin
            read_dummy_cycle_index_q <= read_dummy_cycle_index_q + 3'd1;
          end
        end

        // Return one nibble per SCK.
        // Each byte is returned upper nibble first, then lower nibble.
        TRANSACTION_STATE_SEND_READ_DATA: begin
          dio_output_enable_q <= 1'b1;

          if (read_data_nibble_position_q == NIBBLE_POSITION_UPPER) begin
            dio_output_nibble_q <=
              psram_byte_array[transaction_byte_addr_q[21:0]][7:4];

            read_data_nibble_position_q <= NIBBLE_POSITION_LOWER;
          end else begin
            dio_output_nibble_q <=
              psram_byte_array[transaction_byte_addr_q[21:0]][3:0];

            read_data_nibble_position_q <= NIBBLE_POSITION_UPPER;
            transaction_byte_addr_q     <= transaction_byte_addr_q + 24'd1;
          end
        end

        // Receive one nibble per SCK.
        // Combine the upper and lower nibbles into one byte.
        TRANSACTION_STATE_RECEIVE_WRITE_DATA: begin
          dio_output_enable_q <= 1'b0;

          if (write_data_nibble_position_q == NIBBLE_POSITION_UPPER) begin
            write_byte_upper_nibble_q    <= dio_input_nibble;
            write_data_nibble_position_q <= NIBBLE_POSITION_LOWER;
          end else begin
            psram_byte_array[transaction_byte_addr_q[21:0]] <= {
              write_byte_upper_nibble_q,
              dio_input_nibble
            };

            write_data_nibble_position_q <= NIBBLE_POSITION_UPPER;
            transaction_byte_addr_q      <= transaction_byte_addr_q + 24'd1;
          end
        end

        // Ignore unsupported commands until ce_n becomes high.
        TRANSACTION_STATE_IGNORE_UNSUPPORTED_COMMAND: begin
          dio_output_enable_q <= 1'b0;
        end

        default: begin
          transaction_state_q <= TRANSACTION_STATE_IGNORE_UNSUPPORTED_COMMAND;
          dio_output_enable_q <= 1'b0;
        end

      endcase
    end
  end

endmodule
