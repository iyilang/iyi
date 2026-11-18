require "../support/syntax"
require "../../src/compiler/iyi/syntax/bound_path_index"

private def spans(text : String, entry : Iyi::BoundPathIndex::Entry) : Array({Int32, Int32, Array(String)})
  Iyi::BoundPathIndex.paths(text, entry, false).map { |path| {path.start, path.finish, path.names} }
end

describe Iyi::BoundPathIndex do
  it "reports each path at its bytes and skips what a string spells" do
    text = %(Root::A.new(::Root::B, "Root::C", Other::Root))
    spans(text, :expression).should eq([{0, 7, ["Root", "A"]}, {14, 21, ["Root", "B"]}, {34, 45, ["Other", "Root"]}])
  end

  it "reports the bytes either side of a path" do
    paths = Iyi::BoundPathIndex.paths("x(::Root::B)", :expression, false)
    paths.size.should eq(1)
    paths[0].before.should eq(':'.ord.to_u8)
    paths[0].after_first.should eq(':'.ord.to_u8)
    paths[0].after.should eq(')'.ord.to_u8)
  end

  it "counts bytes, not characters" do
    spans(%(puts "é", Root::A), :body).should eq([{11, 18, ["Root", "A"]}])
  end

  it "does not report a name of the source the text is read inside" do
    spans("fun open(flags : A) : B", :fun_line).should eq([{17, 18, ["A"]}, {22, 23, ["B"]}])
    spans("value : A", :parameter).should eq([{8, 9, ["A"]}])
  end

  it "forgets the paths a lookahead read once the lookahead is undone" do
    parser = Iyi::BoundPathIndex::PathReader.new("Root::X")
    parser.next_token
    parser.peek_ahead { parser.parse_path }
    parser.paths.should be_empty
    parser.parse_path
    parser.paths.map(&.[0]).should eq([["Root", "X"]])
  end

  it "reports a path on a later line, after a line that holds wider characters" do
    spans(%(puts "é"\nRoot::A.new), :body).should eq([{10, 17, ["Root", "A"]}])
  end

  it "raises on text no entry can read" do
    expect_raises(ArgumentError, "bound text cannot be read as source") do
      Iyi::BoundPathIndex.paths(%[Root::A.new("open], :body, false)
    end
  end
end
