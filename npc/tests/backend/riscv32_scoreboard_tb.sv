module riscv32_scoreboard_tb;
  import riscv32_pkg::*;
  decoded_uop_t decoded;
  xlen_data_t rf_a, rf_b, result_a, result_b;
  execute_producer_t producer_array[BACKEND_ENTRIES];
  backend_tag_t head;
  logic empty, raw, serializing;
  riscv32_scoreboard dut (
      .issue_uop_i(decoded), .rs1_i(rf_a), .rs2_i(rf_b),
      .producer_array_i(producer_array), .head_tag_i(head), .empty_i(empty),
      .rs1_o(result_a), .rs2_o(result_b), .raw_o(raw), .serializing_o(serializing)
  );

  initial begin
    for (int trial = 0; trial < 10000; trial++) begin
      decoded = '0;
      decoded.rs1 = 5'($urandom_range(0, 7));
      decoded.rs2 = 5'($urandom_range(0, 7));
      decoded.uses_rs1 = 1'($urandom);
      decoded.uses_rs2 = 1'($urandom);
      decoded.serializing = ($urandom_range(0, 19) == 0);
      decoded.exception_valid = ($urandom_range(0, 19) == 0);
      rf_a = xlen_data_t'($urandom);
      rf_b = xlen_data_t'($urandom);
      head = backend_tag_t'($urandom_range(0, BACKEND_ENTRIES - 1));
      empty = 1'b1;
      for (int slot = 0; slot < BACKEND_ENTRIES; slot++) begin
        producer_array[slot] = '0;
        producer_array[slot].present = 1'($urandom);
        producer_array[slot].writes_rd = 1'($urandom);
        producer_array[slot].forwardable = 1'($urandom);
        producer_array[slot].serializing = ($urandom_range(0, 19) == 0);
        producer_array[slot].rd = 5'($urandom_range(0, 7));
        producer_array[slot].value = xlen_data_t'($urandom);
        empty &= !producer_array[slot].present;
      end
      #1;
      begin
        xlen_data_t expected_a, expected_b;
        logic ready_a, ready_b, expected_serializing;
        int youngest_a, youngest_b;
        expected_a = decoded.rs1 == 0 ? '0 : rf_a;
        expected_b = decoded.rs2 == 0 ? '0 : rf_b;
        ready_a = 1'b1;
        ready_b = 1'b1;
        youngest_a = -1;
        youngest_b = -1;
        expected_serializing = decoded.serializing && !empty;
        for (int slot = 0; slot < BACKEND_ENTRIES; slot++) begin
          int age;
          age = (slot + BACKEND_ENTRIES - int'(head)) % BACKEND_ENTRIES;
          if (producer_array[slot].present) begin
            expected_serializing |= producer_array[slot].serializing;
            if (producer_array[slot].writes_rd && producer_array[slot].rd != 0) begin
              if (decoded.uses_rs1 && decoded.rs1 == producer_array[slot].rd && age > youngest_a) begin
                youngest_a = age;
                expected_a = producer_array[slot].value;
                ready_a = producer_array[slot].forwardable;
              end
              if (decoded.uses_rs2 && decoded.rs2 == producer_array[slot].rd && age > youngest_b) begin
                youngest_b = age;
                expected_b = producer_array[slot].value;
                ready_b = producer_array[slot].forwardable;
              end
            end
          end
        end
        assert (result_a == expected_a && result_b == expected_b)
          else $fatal(1, "source version mismatch trial=%0d", trial);
        assert (raw == (!decoded.exception_valid && (!ready_a || !ready_b)))
          else $fatal(1, "source readiness mismatch trial=%0d", trial);
        assert (serializing == expected_serializing)
          else $fatal(1, "serializing mismatch trial=%0d", trial);
      end
    end
    $display("PASS scoreboard entries=%0d cases=10000", BACKEND_ENTRIES);
    $finish;
  end
endmodule
