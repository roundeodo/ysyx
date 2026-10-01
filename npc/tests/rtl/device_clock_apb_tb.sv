`timescale 1ns / 1ns
module device_clock_apb_tb #(
    parameter integer CPU_MHZ = 720
);
  logic clock;
  logic reset;
  logic [31:0] in_paddr;
  logic in_psel;
  logic in_penable;
  logic [2:0] in_pprot;
  logic in_pwrite;
  logic [31:0] in_pwdata;
  logic [3:0] in_pstrb;
  logic in_pready;
  logic [31:0] in_prdata;
  logic in_pslverr;
  logic [31:0] out_paddr;
  logic out_psel;
  logic out_penable;
  logic [2:0] out_pprot;
  logic out_pwrite;
  logic [31:0] out_pwdata;
  logic [3:0] out_pstrb;
  logic out_pready;
  logic [31:0] out_prdata;
  logic out_pslverr;
  wire device_clock_o;
  apb_delayer #(
      .CPU_FREQUENCY_HZ  (64'd1000000 * CPU_MHZ),
      .DEVICE_TIMING_MODE(1)
  ) dut (
      .*
  );
  initial begin
    clock = 0;
    forever #1 clock = ~clock;
  end
  integer cpu_cycle = 0, device_cycles = 0, setup_device_cycle = 0, wait_q = 0;
  integer delay_setting = 0, completions = 0, writes = 0, expected_writes = 0;
  integer transaction = 0;
  logic   saw_setup = 0;
  assign out_pready  = wait_q == delay_setting;
  assign out_prdata  = out_paddr ^ 32'h715a963c;
  assign out_pslverr = out_paddr[5];

  // Independent device: setup is followed by N wait edges and one completion.
  always @(posedge device_clock_o) begin
    if (reset) begin
      wait_q = 0;
      saw_setup = 0;
      device_cycles = 0;
      completions = 0;
      writes = 0;
    end else begin
      device_cycles++;
      if (out_psel && !out_penable) begin
        saw_setup = 1;
        setup_device_cycle = device_cycles;
        wait_q = 0;
      end
      if (out_psel && out_penable) begin
        assert (saw_setup)
        else $fatal(1, "ACCESS without device SETUP");
        if (out_pready) begin
          assert (device_cycles - setup_device_cycle == delay_setting + 1)
          else $fatal(1, "wrong device service interval");
          assert (out_paddr == in_paddr && out_pwdata == in_pwdata && out_pstrb == in_pstrb)
          else $fatal(1, "APB payload mismatch");
          completions++;
          if (out_pwrite) writes++;
          saw_setup = 0;
        end else wait_q++;
      end
    end
  end

  always @(posedge clock) begin
    if (reset) cpu_cycle = 0;
    else begin
      cpu_cycle++;
      // A separate closed-form bound, not a copy of the RTL phase recurrence.
      assert(device_cycles*CPU_MHZ <= (cpu_cycle+1)*100+CPU_MHZ &&
             device_cycles*CPU_MHZ >= (cpu_cycle-1)*100-CPU_MHZ)
      else $fatal(1, "device clock drift");
    end
  end

  task automatic transfer(input integer index);
    integer start_count;
    begin
      @(negedge clock);
      delay_setting = index % 8;
      start_count = completions;
      in_paddr = 32'h10000000 + index * 4;
      in_pwdata = 32'h98760000 + index;
      in_pstrb = 4'(index);
      in_pwrite = index % 2;
      in_psel = 1;
      in_penable = 0;
      @(negedge clock);
      in_penable = 1;
      do @(posedge clock); while (!in_pready);
      assert (in_prdata == (in_paddr ^ 32'h715a963c) && in_pslverr == in_paddr[5])
      else $fatal(1, "APB response mismatch");
      if (in_pwrite) expected_writes++;
      @(negedge clock);
      in_psel = 0;
      in_penable = 0;
      assert (completions == start_count + 1 && writes == expected_writes)
      else $fatal(1, "APB side effect duplicated or lost");
      repeat (index % 3) @(negedge clock);
    end
  endtask
  initial begin
    reset = 1;
    in_psel = 0;
    in_penable = 0;
    in_paddr = 0;
    in_pwdata = 0;
    in_pwrite = 0;
    in_pstrb = 0;
    in_pprot = 0;
    repeat (4) @(negedge clock);
    reset = 0;
    for (transaction = 0; transaction < 64; transaction++) transfer(transaction);
    // Reset during a slow access must discard it without a late response.
    @(negedge clock);
    in_psel = 1;
    in_penable = 0;
    delay_setting = 100;
    @(negedge clock);
    in_penable = 1;
    repeat (20) @(negedge clock);
    reset = 1;
    in_psel = 0;
    in_penable = 0;
    repeat (4) @(negedge clock);
    reset = 0;
    expected_writes = 0;
    transfer(1);
    $display("PASS APB cpu_mhz=%0d transactions=65 reset_in_access=1", CPU_MHZ);
    $finish;
  end
  initial begin
    #300000;
    $fatal(1, "APB timeout");
  end
endmodule
