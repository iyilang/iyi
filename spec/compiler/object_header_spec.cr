require "spec"
require "compiler/iyi/object_header"

# iyi: the object header and its mark word. GC_DESIGN.md, Stage 1 task 2.
#
# The design's verification line for this unit: "object headers are the right
# size; mark word bit manipulations are CAS-safe." These specs take that
# adversarially. The size is asserted, not assumed. Every transition that
# must fail is made to fail. The concurrency test is a real race between two
# threads parked on the same gate word, not two sequential shades with a join
# between them, and the shared words live on the heap because an Atomic
# copied into a proc argument is a different word.
private alias ObjectHeader = Iyi::Collector::ObjectHeader
private alias Color = Iyi::Collector::Color

# Two threads race to shade the same white object, once per round. Both
# claimants spin on the gate, so each round releases them within a cache
# line's flight time of each other and the loser's CAS genuinely loses.
private class ShadingRace
  @header = ObjectHeader.new(0_u32)
  @gate = Atomic(Int32).new(0)
  @ack = Atomic(Int32).new(0)
  @wins_a = 0
  @wins_b = 0

  def run(rounds : Int32) : {Int32, Int32}
    thread_a = Thread.new(name: "shading-race-a") { claim(rounds, a: true) }
    thread_b = Thread.new(name: "shading-race-b") { claim(rounds, a: false) }

    rounds.times do |round|
      @header = ObjectHeader.new(0_u32)
      @gate.add(1)
      until @ack.get == 2 * (round + 1)
        Thread.yield
      end
      # Exactly one winner per round, checked per round so a double win
      # cannot hide inside the totals. The loser leaving the object alone is
      # the whole point of the race answer.
      (@wins_a + @wins_b).should eq(round + 1)
      @header.color.should eq Color::Gray
    end

    thread_a.join
    thread_b.join
    {@wins_a, @wins_b}
  end

  private def claim(rounds : Int32, a : Bool) : Nil
    seen = 0
    while seen < rounds
      if (current = @gate.get) > seen
        seen = current
        won = @header.shade_gray
        if a
          @wins_a += 1 if won
        else
          @wins_b += 1 if won
        end
        @ack.add(1)
      else
        Thread.yield
      end
    end
  end
end

describe Iyi::Collector::ObjectHeader do
  it "is one word" do
    sizeof(ObjectHeader).should eq 8
  end

  it "lays out the colour and flags in the low bits and the type id in the high half" do
    buffer = Pointer(ObjectHeader).malloc(1)
    buffer.value = ObjectHeader.new(7_u32)

    # Little-endian, like every target iyi compiles for and like `.iyimod`:
    # the type id is the u32 at byte 4, which is where codegen stores it.
    buffer.as(UInt64*).value.should eq 7_u64 << 32
    (buffer.as(UInt8*) + 4).as(UInt32*).value.should eq 7_u32

    # Shading through the pointer, the access shape the marker uses against
    # a header ahead of a heap object, touches only the colour bits.
    buffer.value.shade_gray.should be_true
    buffer.as(UInt64*).value.should eq (7_u64 << 32) | 1_u64
    buffer.value.type_id.should eq 7_u32
  end

  it "starts white with no flags and no payload" do
    header = ObjectHeader.new(0_u32)
    header.color.should eq Color::White
    header.has_finalizer?.should be_false
    header.pinned?.should be_false
    header.payload.should eq 0_u64
  end

  describe "colour transitions" do
    it "shades a white object gray and reports the win" do
      header = ObjectHeader.new(0_u32)
      header.shade_gray.should be_true
      header.color.should eq Color::Gray
    end

    it "shades a gray object black and reports the win" do
      header = ObjectHeader.new(0_u32)
      header.shade_gray
      header.shade_black.should be_true
      header.color.should eq Color::Black
    end

    it "refuses to shade a white object black directly" do
      header = ObjectHeader.new(0_u32)
      header.shade_black.should be_false
      header.color.should eq Color::White
    end

    it "refuses to shade a gray object gray a second time" do
      header = ObjectHeader.new(0_u32)
      header.shade_gray.should be_true
      header.shade_gray.should be_false
      header.color.should eq Color::Gray
    end

    it "refuses every transition out of black" do
      header = ObjectHeader.new(0_u32)
      header.shade_gray
      header.shade_black
      header.shade_gray.should be_false
      header.shade_black.should be_false
      header.color.should eq Color::Black
    end
  end

  it "keeps the two flags independent of each other" do
    header = ObjectHeader.new(0_u32)
    header.mark_has_finalizer
    header.has_finalizer?.should be_true
    header.pinned?.should be_false
    header.pin
    header.has_finalizer?.should be_true
    header.pinned?.should be_true
  end

  it "keeps flags across colour changes" do
    header = ObjectHeader.new(0_u32)
    header.mark_has_finalizer
    header.pin
    header.shade_gray
    header.shade_black
    header.color.should eq Color::Black
    header.has_finalizer?.should be_true
    header.pinned?.should be_true
  end

  it "keeps colour across flag changes" do
    header = ObjectHeader.new(0_u32)
    header.shade_gray
    header.mark_has_finalizer
    header.pin
    header.color.should eq Color::Gray
  end

  it "still changes colour after flags are set, and loses neither" do
    # A transition that rebuilt its desired word from a stale read instead of
    # the value the lost CAS handed back would fail here one way or the
    # other: it would write the flags away, or refuse the transition.
    header = ObjectHeader.new(0_u32)
    header.mark_has_finalizer
    header.shade_gray.should be_true
    header.pin
    header.shade_black.should be_true
    header.color.should eq Color::Black
    header.has_finalizer?.should be_true
    header.pinned?.should be_true
  end

  it "round trips the reserved payload through colour and flag operations" do
    header = ObjectHeader.new(0_u32)
    header.payload = 0x0123_4567_u64
    header.payload.should eq 0x0123_4567_u64
    header.shade_gray
    header.mark_has_finalizer
    header.pin
    header.shade_black
    header.payload.should eq 0x0123_4567_u64
    header.color.should eq Color::Black
    header.has_finalizer?.should be_true
    header.pinned?.should be_true
  end

  it "accepts the largest payload the reserved bits hold, and owns no bit below them" do
    header = ObjectHeader.new(0_u32)
    header.payload = ObjectHeader::PAYLOAD_MAX
    header.payload.should eq ObjectHeader::PAYLOAD_MAX
    header.color.should eq Color::White
    header.has_finalizer?.should be_false
    header.pinned?.should be_false
  end

  it "refuses a payload that does not fit instead of truncating it" do
    header = ObjectHeader.new(0_u32)
    expect_raises(ArgumentError) do
      header.payload = ObjectHeader::PAYLOAD_MAX + 1
    end
    header.payload.should eq 0_u64
  end

  it "stores the extreme type ids" do
    ObjectHeader.new(0_u32).type_id.should eq 0_u32
    ObjectHeader.new(UInt32::MAX).type_id.should eq UInt32::MAX
  end

  it "lets exactly one of two concurrent claimants shade the same white object" do
    # 10,000 rounds rather than 1,000, because of what the split looks like when
    # measured: at 1,000 rounds it came out 32/968, at 10,000 it is 5012/4988,
    # and at 100,000 it is 58498/41502. Ten thousand rounds costs about 9ms.
    #
    # The one-winner invariant holds at every size and is checked on every
    # attempt. The contention proof is a probability, and the note that used to
    # sit here said 32/968 was one unlucky schedule away from a zero and a spec
    # that flakes on a loaded machine. It then flaked on a loaded runner,
    # exactly there, with wins_a at 0. Knowing a check is load-bearing on luck
    # and leaving it is what made that a failure rather than a finding.
    #
    # So contention is now asked several times before it is disbelieved. One
    # starved attempt is a schedule; every attempt starved is the threads never
    # contending, which is the thing worth failing over.
    rounds = 10_000
    attempts = 5
    contended = false

    attempts.times do
      wins_a, wins_b = ShadingRace.new.run(rounds)

      # The actual invariant: every round has exactly one winner, so the two
      # tallies account for all of them and neither claimant double-counts.
      (wins_a + wins_b).should eq rounds

      if wins_a > 0 && wins_b > 0
        contended = true
        break
      end
    end

    fail "both claimants starved in #{attempts} attempts of #{rounds} rounds" unless contended
  end
end
