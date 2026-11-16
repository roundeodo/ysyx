module choice_formal (
    input logic [31:0] pc, target,
    input logic metadata,
    input logic [1:0] counter
);
  wire [2:0] prediction;
  wire [12:0] narrow_displacement=target[12:0]-pc[12:0];
  logic [31:0] displacement;
  assign displacement=target-pc;
  for(genvar p=0;p<3;p++)begin: g_policy
    riscv32_branch_choice #(.POLICY(p)) dut (
      .backward_i(narrow_displacement[12]),.metadata_valid_i(metadata),
      .dynamic_counter_i(counter),.taken_o(prediction[p]));
  end
  always_comb begin
    assume(displacement[31:13]=={19{displacement[12]}});
    assert(prediction[0]==counter[1]);
    assert(prediction[1]==(metadata ? displacement[31] : counter[1]));
    case(counter)
      0:assert(prediction[2]==0);
      3:assert(prediction[2]==1);
      default:assert(prediction[2]==(metadata ? displacement[31] : counter[1]));
    endcase
  end
endmodule
