// 小界形式化验证只覆盖流水线传输和冒险决策，不替代整核ISA等价验证。
// fetch queue使用独立的移位式参考模型检查顺序；hazard controller使用组合不变量检查
// 最新生产者优先、不可用数据停顿和可用数据前递。
module riscv32_pipeline_control_formal;
  import riscv32_pkg::*;

  (* gclk *)logic clk_i;
  logic rst_ni = 1'b0;

  always_ff @(posedge clk_i) begin
    rst_ni <= 1'b1;
  end

  // --------------------------------------------------------------------------
  // Fetch queue reference model
  // --------------------------------------------------------------------------

  (* anyseq *)logic         [7:0] fetch_entry_token_from_ifu;
  fetch_entry_t       fetch_entry_from_ifu;
  (* anyseq *)logic               fetch_entry_from_ifu_valid;
  logic               fetch_entry_from_ifu_ready;
  fetch_entry_t       fetch_entry_to_idu;
  logic               fetch_entry_to_idu_valid;
  (* anyseq *)logic               fetch_entry_to_idu_ready;
  (* anyseq *)logic               fetch_queue_flush;

  // 形式模型只用PC低8位作为顺序token，避免无关payload位扩大求解空间。
  // DUT仍然实例化真实fetch_entry_t，因此队列的真实宽度、指针和控制逻辑没有简化。
  always_comb begin
    fetch_entry_from_ifu    = '0;
    fetch_entry_from_ifu.pc = program_counter_t'(fetch_entry_token_from_ifu);
  end

  riscv32_fetch_buffer u_fetch_buffer (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .ifu_fetch_entry_i      (fetch_entry_from_ifu),
      .ifu_fetch_entry_valid_i(fetch_entry_from_ifu_valid),
      .ifu_fetch_entry_ready_o(fetch_entry_from_ifu_ready),
      .idu_fetch_entry_o      (fetch_entry_to_idu),
      .idu_fetch_entry_valid_o(fetch_entry_to_idu_valid),
      .idu_fetch_entry_ready_i(fetch_entry_to_idu_ready),
      .flush_i                (fetch_queue_flush)
  );

  logic       fetch_enqueue_occurred;
  logic       fetch_dequeue_occurred;
  logic [7:0] expected_first_token_q;
  logic [7:0] expected_second_token_q;
  logic [1:0] expected_entry_count_q;
  logic       formal_past_valid_q = 1'b0;
  logic       previous_ifu_fetch_entry_valid_q;
  logic       previous_ifu_fetch_entry_ready_q;
  logic [7:0] previous_ifu_fetch_entry_token_q;

  assign fetch_enqueue_occurred = fetch_entry_from_ifu_valid && fetch_entry_from_ifu_ready;
  assign fetch_dequeue_occurred = fetch_entry_to_idu_valid && fetch_entry_to_idu_ready;

  // 合法ready/valid生产者在反压期间必须保持valid和payload。
  always_ff @(posedge clk_i) begin
    if (formal_past_valid_q && previous_ifu_fetch_entry_valid_q &&
        !previous_ifu_fetch_entry_ready_q) begin
      assume (fetch_entry_from_ifu_valid);
      assume (fetch_entry_token_from_ifu == previous_ifu_fetch_entry_token_q);
    end

    formal_past_valid_q <= 1'b1;
    previous_ifu_fetch_entry_valid_q <= fetch_entry_from_ifu_valid;
    previous_ifu_fetch_entry_ready_q <= fetch_entry_from_ifu_ready;
    previous_ifu_fetch_entry_token_q <= fetch_entry_token_from_ifu;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni || fetch_queue_flush) begin
      expected_entry_count_q <= '0;
    end else begin
      unique case ({
        fetch_enqueue_occurred, fetch_dequeue_occurred
      })
        2'b10: begin
          if (expected_entry_count_q == 2'd0) begin
            expected_first_token_q <= fetch_entry_token_from_ifu;
          end else begin
            expected_second_token_q <= fetch_entry_token_from_ifu;
          end
          expected_entry_count_q <= expected_entry_count_q + 2'd1;
        end

        2'b01: begin
          if (expected_entry_count_q == 2'd2) begin
            expected_first_token_q <= expected_second_token_q;
          end
          expected_entry_count_q <= expected_entry_count_q - 2'd1;
        end

        2'b11: begin
          if (expected_entry_count_q == 2'd1) begin
            expected_first_token_q <= fetch_entry_token_from_ifu;
          end else begin
            expected_first_token_q  <= expected_second_token_q;
            expected_second_token_q <= fetch_entry_token_from_ifu;
          end
        end

        default: ;
      endcase
    end
  end

  always_comb begin
    if (rst_ni) begin
      assert (expected_entry_count_q <= 2'd2);
      assert (fetch_entry_to_idu_valid == (expected_entry_count_q != 2'd0));
      // DUT刻意不使用IDU本拍ready组合旁路入口ready，以切断后端冒险判断到IFU的长路径。
      // 因而队列满时，即使本拍同时出队，也要到下一拍才能重新接收IFU entry。
      assert (fetch_entry_from_ifu_ready ==
              (!fetch_queue_flush && (expected_entry_count_q != 2'd2)));
      if (fetch_entry_to_idu_valid) begin
        assert (fetch_entry_to_idu.pc[7:0] == expected_first_token_q);
      end
    end
  end

  // --------------------------------------------------------------------------
  // Hazard and forwarding decision invariants
  // --------------------------------------------------------------------------

  (* anyseq *)logic          decoded_uop_valid;
  (* anyseq *)logic          decoded_uses_rs1;
  (* anyseq *)arch_reg_idx_t decoded_rs1;
  (* anyseq *)logic          decoded_uses_rs2;
  (* anyseq *)arch_reg_idx_t decoded_rs2;
  (* anyseq *)logic          decoded_serializing;
  (* anyseq *)logic          execute_uop_valid;
  (* anyseq *)logic          execute_writes_rd;
  (* anyseq *)arch_reg_idx_t execute_rd;
  (* anyseq *)logic          execute_serializing;
  (* anyseq *)logic          execute_forwarding_available;
  (* anyseq *)logic          execute_result_valid;
  (* anyseq *)logic          execute_result_exception_valid;
  (* anyseq *)logic          execute_result_writes_rd;
  (* anyseq *)arch_reg_idx_t execute_result_rd;
  (* anyseq *)logic          execute_result_forwarding_available;
  (* anyseq *)logic          writeback_result_valid;
  (* anyseq *)logic          writeback_writes_rd;
  (* anyseq *)arch_reg_idx_t writeback_rd;
  (* anyseq *)logic          writeback_serializing;
  (* anyseq *)logic          writeback_forwarding_available;
  (* anyseq *)logic          lsu_busy;
  (* anyseq *)logic          lsu_pending_writes_rd;
  (* anyseq *)arch_reg_idx_t lsu_pending_rd;
  (* anyseq *)logic          lsu_forwarding_available;
  (* anyseq *)logic          frontend_redirect_applied;
  (* anyseq *)logic          commit_redirect_event;

  logic          decode_accept_allowed;
  logic          execute_issue_allowed;
  logic          decode_execute_flush;
  logic          writeback_flush;
  logic          raw_hazard_present;
  logic          serializing_hazard_present;
  logic          structural_hazard_present;
  logic          rs1_execute_forwarding_selected;
  logic          rs1_execute_result_forwarding_selected;
  logic          rs1_lsu_forwarding_selected;
  logic          rs1_writeback_forwarding_selected;
  logic          rs2_execute_forwarding_selected;
  logic          rs2_execute_result_forwarding_selected;
  logic          rs2_lsu_forwarding_selected;
  logic          rs2_writeback_forwarding_selected;

  logic          execute_matches_rs1;
  logic          execute_matches_rs2;
  logic          execute_result_matches_rs1;
  logic          execute_result_matches_rs2;
  logic          writeback_matches_rs1;
  logic          writeback_matches_rs2;
  logic          lsu_matches_rs1;
  logic          lsu_matches_rs2;

  riscv32_hazard_ctrl u_hazard_ctrl (
      .clk_i                                   (clk_i),
      .rst_ni                                  (rst_ni),
      .decoded_uop_valid_i                     (decoded_uop_valid),
      .decoded_uses_rs1_i                      (decoded_uses_rs1),
      .decoded_rs1_i                           (decoded_rs1),
      .decoded_uses_rs2_i                      (decoded_uses_rs2),
      .decoded_rs2_i                           (decoded_rs2),
      .decoded_serializing_i                   (decoded_serializing),
      .execute_uop_valid_i                     (execute_uop_valid),
      .execute_writes_rd_i                     (execute_writes_rd),
      .execute_rd_i                            (execute_rd),
      .execute_serializing_i                   (execute_serializing),
      .execute_forwarding_available_i          (execute_forwarding_available),
      .execute_result_valid_i                  (execute_result_valid),
      .execute_result_ready_i                  (1'b1),
      .execute_result_exception_valid_i        (execute_result_exception_valid),
      .execute_result_writes_rd_i              (execute_result_writes_rd),
      .execute_result_rd_i                     (execute_result_rd),
      .execute_result_forwarding_available_i   (execute_result_forwarding_available),
      .execute_result_serializing_i            (1'b0),
      .writeback_result_valid_i                (writeback_result_valid),
      .writeback_writes_rd_i                   (writeback_writes_rd),
      .writeback_rd_i                          (writeback_rd),
      .writeback_serializing_i                 (writeback_serializing),
      .writeback_forwarding_available_i        (writeback_forwarding_available),
      .lsu_busy_i                              (lsu_busy),
      .lsu_pending_writes_rd_i                 (lsu_pending_writes_rd),
      .lsu_pending_rd_i                        (lsu_pending_rd),
      .lsu_forwarding_available_i              (lsu_forwarding_available),
      .execute_redirect_present_i              (1'b0),
      .frontend_redirect_applied_i             (frontend_redirect_applied),
      .commit_redirect_event_i              (commit_redirect_event),
      .decode_accept_allowed_o                 (decode_accept_allowed),
      .execute_issue_allowed_o                 (execute_issue_allowed),
      .decode_execute_flush_o                  (decode_execute_flush),
      .writeback_flush_o                       (writeback_flush),
      .raw_hazard_present_o                    (raw_hazard_present),
      .serializing_hazard_present_o            (serializing_hazard_present),
      .structural_hazard_present_o             (structural_hazard_present),
      .rs1_execute_forwarding_selected_o       (rs1_execute_forwarding_selected),
      .rs1_execute_result_forwarding_selected_o(rs1_execute_result_forwarding_selected),
      .rs1_lsu_forwarding_selected_o           (rs1_lsu_forwarding_selected),
      .rs1_writeback_forwarding_selected_o     (rs1_writeback_forwarding_selected),
      .rs2_execute_forwarding_selected_o       (rs2_execute_forwarding_selected),
      .rs2_execute_result_forwarding_selected_o(rs2_execute_result_forwarding_selected),
      .rs2_lsu_forwarding_selected_o           (rs2_lsu_forwarding_selected),
      .rs2_writeback_forwarding_selected_o     (rs2_writeback_forwarding_selected)
  );

  always_comb begin
    execute_matches_rs1 = decoded_uop_valid && decoded_uses_rs1 && execute_uop_valid &&
                          execute_writes_rd && (execute_rd != '0) &&
                          (execute_rd == decoded_rs1);
    execute_matches_rs2 = decoded_uop_valid && decoded_uses_rs2 && execute_uop_valid &&
                          execute_writes_rd && (execute_rd != '0) &&
                          (execute_rd == decoded_rs2);
    execute_result_matches_rs1 = decoded_uop_valid && decoded_uses_rs1 &&
                                 execute_result_valid && execute_result_writes_rd &&
                                 (execute_result_rd != '0) &&
                                 (execute_result_rd == decoded_rs1);
    execute_result_matches_rs2 = decoded_uop_valid && decoded_uses_rs2 &&
                                 execute_result_valid && execute_result_writes_rd &&
                                 (execute_result_rd != '0) &&
                                 (execute_result_rd == decoded_rs2);
    writeback_matches_rs1 = decoded_uop_valid && decoded_uses_rs1 && writeback_result_valid &&
                            writeback_writes_rd && (writeback_rd != '0) &&
                            (writeback_rd == decoded_rs1);
    writeback_matches_rs2 = decoded_uop_valid && decoded_uses_rs2 && writeback_result_valid &&
                            writeback_writes_rd && (writeback_rd != '0) &&
                            (writeback_rd == decoded_rs2);
    lsu_matches_rs1 = decoded_uop_valid && decoded_uses_rs1 && lsu_busy &&
                      lsu_pending_writes_rd && (lsu_pending_rd != '0) &&
                      (lsu_pending_rd == decoded_rs1);
    lsu_matches_rs2 = decoded_uop_valid && decoded_uses_rs2 && lsu_busy &&
                      lsu_pending_writes_rd && (lsu_pending_rd != '0) &&
                      (lsu_pending_rd == decoded_rs2);

    if (rst_ni) begin
      // yosys-slang当前不支持$onehot0，四项选择显式展开为两两互斥。
      assert (!(rs1_execute_forwarding_selected && rs1_lsu_forwarding_selected));
      assert (!(rs1_execute_forwarding_selected && rs1_execute_result_forwarding_selected));
      assert (!(rs1_execute_forwarding_selected && rs1_writeback_forwarding_selected));
      assert (!(rs1_execute_result_forwarding_selected && rs1_lsu_forwarding_selected));
      assert (!(rs1_execute_result_forwarding_selected && rs1_writeback_forwarding_selected));
      assert (!(rs1_lsu_forwarding_selected && rs1_writeback_forwarding_selected));
      assert (!(rs2_execute_forwarding_selected && rs2_lsu_forwarding_selected));
      assert (!(rs2_execute_forwarding_selected && rs2_execute_result_forwarding_selected));
      assert (!(rs2_execute_forwarding_selected && rs2_writeback_forwarding_selected));
      assert (!(rs2_execute_result_forwarding_selected && rs2_lsu_forwarding_selected));
      assert (!(rs2_execute_result_forwarding_selected && rs2_writeback_forwarding_selected));
      assert (!(rs2_lsu_forwarding_selected && rs2_writeback_forwarding_selected));
      assert (decoded_uop_valid ||
              !(rs1_execute_forwarding_selected || rs1_execute_result_forwarding_selected ||
                rs1_lsu_forwarding_selected ||
                rs1_writeback_forwarding_selected || rs2_execute_forwarding_selected ||
                rs2_execute_result_forwarding_selected || rs2_lsu_forwarding_selected ||
                rs2_writeback_forwarding_selected));

      if (execute_matches_rs1) begin
        assert (rs1_execute_forwarding_selected == execute_forwarding_available);
        assert (!rs1_writeback_forwarding_selected);
        assert (execute_forwarding_available || raw_hazard_present);
      end else if (execute_result_matches_rs1) begin
        assert (rs1_execute_result_forwarding_selected == execute_result_forwarding_available);
        assert (!rs1_lsu_forwarding_selected && !rs1_writeback_forwarding_selected);
        assert (execute_result_forwarding_available || raw_hazard_present);
      end else if (lsu_matches_rs1) begin
        assert (rs1_lsu_forwarding_selected == lsu_forwarding_available);
        assert (!rs1_writeback_forwarding_selected);
        assert (lsu_forwarding_available || raw_hazard_present);
      end else if (writeback_matches_rs1) begin
        assert (rs1_writeback_forwarding_selected == writeback_forwarding_available);
        assert (writeback_forwarding_available || raw_hazard_present);
      end

      if (execute_matches_rs2) begin
        assert (rs2_execute_forwarding_selected == execute_forwarding_available);
        assert (!rs2_writeback_forwarding_selected);
        assert (execute_forwarding_available || raw_hazard_present);
      end else if (execute_result_matches_rs2) begin
        assert (rs2_execute_result_forwarding_selected == execute_result_forwarding_available);
        assert (!rs2_lsu_forwarding_selected && !rs2_writeback_forwarding_selected);
        assert (execute_result_forwarding_available || raw_hazard_present);
      end else if (lsu_matches_rs2) begin
        assert (rs2_lsu_forwarding_selected == lsu_forwarding_available);
        assert (!rs2_writeback_forwarding_selected);
        assert (lsu_forwarding_available || raw_hazard_present);
      end else if (writeback_matches_rs2) begin
        assert (rs2_writeback_forwarding_selected == writeback_forwarding_available);
        assert (writeback_forwarding_available || raw_hazard_present);
      end

      assert (!(raw_hazard_present || serializing_hazard_present ||
                frontend_redirect_applied || commit_redirect_event) ||
              !decode_accept_allowed);
      assert ((raw_hazard_present || serializing_hazard_present || structural_hazard_present ||
                (execute_result_valid && execute_result_exception_valid) ||
                frontend_redirect_applied ||
                commit_redirect_event) ||
              (decode_accept_allowed && execute_issue_allowed));
      assert (!lsu_busy || !execute_issue_allowed);
      assert (!frontend_redirect_applied || !execute_issue_allowed);
      assert (!commit_redirect_event || !execute_issue_allowed);
      assert (!(frontend_redirect_applied || commit_redirect_event) || decode_execute_flush);
      assert (!(lsu_busy || frontend_redirect_applied || commit_redirect_event) ||
              !execute_issue_allowed);
      assert ((lsu_busy || frontend_redirect_applied || commit_redirect_event ||
               (execute_result_valid && execute_result_exception_valid)) ||
              execute_issue_allowed);
      assert (!(execute_result_valid && execute_result_exception_valid) || !execute_issue_allowed);
      assert (writeback_flush == commit_redirect_event);
    end
  end

endmodule
