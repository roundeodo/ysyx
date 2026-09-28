// Simulation device-time scheduler. Enable changes on the falling CPU edge,
// so both the bridge and the complete device domain observe the same next edge.
// Pulses model digital state updates, not an analog clock or a silicon CDC.
module device_clock #(
    parameter [63:0] CPU_FREQUENCY_HZ = 100_000_000,
    parameter [63:0] DEVICE_FREQUENCY_HZ = 100_000_000
) (
    input clock,
    input reset,
    output device_clock_o,
    output reg device_step_o
);
  reg  [63:0] phase_q;
  wire [63:0] phase_sum = phase_q + DEVICE_FREQUENCY_HZ;

  assign device_clock_o = clock && device_step_o;

  always @(negedge clock) begin
    if (reset) begin
      phase_q       <= 64'd0;
      device_step_o <= 1'b1;
    end else if (phase_sum >= CPU_FREQUENCY_HZ) begin
      phase_q       <= phase_sum - CPU_FREQUENCY_HZ;
      device_step_o <= 1'b1;
    end else begin
      phase_q       <= phase_sum;
      device_step_o <= 1'b0;
    end
  end

  initial begin
    if (DEVICE_FREQUENCY_HZ == 0 || CPU_FREQUENCY_HZ < DEVICE_FREQUENCY_HZ)
      $fatal(1, "device clock requires CPU frequency >= nonzero device frequency");
  end
endmodule
