require "../../spec_helper"

describe "Normalize: case" do
  # iyi: under iyi's prelude, which the specs build with, the select answers
  # whether the arm's operation happened, and an arm nobody binds runs its
  # body only then; the select is told the first bound arm (-1 for none),
  # which a cancelled task's `Cancelled` goes to.
  it "normalizes select with call" do
    assert_expand "select; when foo; body; when bar; baz; end", <<-CODE
      __temp_1, __temp_2, __temp_3 = ::Channel.select({foo_select_action, bar_select_action}, -1)
      case __temp_1
      when 0
        if __temp_3
          body
        end
      when 1
        if __temp_3
          baz
        end
      else
        ::raise("BUG: invalid select index")
      end
      CODE
  end

  it "normalizes select with assign" do
    assert_expand "select; when x = foo; x + 1; end", <<-CODE
      __temp_1, __temp_2, __temp_3 = ::Channel.select({foo_select_action}, 0)
      case __temp_1
      when 0
        x = __temp_2.as(typeof(foo))
        x + 1
      else
        ::raise("BUG: invalid select index")
      end
      CODE
  end

  it "hands a cancelled select to its first bound arm" do
    assert_expand "select; when foo; body; when x = bar; x; end", <<-CODE
      __temp_1, __temp_2, __temp_3 = ::Channel.select({foo_select_action, bar_select_action}, 1)
      case __temp_1
      when 0
        if __temp_3
          body
        end
      when 1
        x = __temp_2.as(typeof(bar))
        x
      else
        ::raise("BUG: invalid select index")
      end
      CODE
  end

  it "normalizes select with else" do
    assert_expand "select; when foo; body; else; baz; end", <<-CODE
      __temp_1, __temp_2, __temp_3 = ::Channel.non_blocking_select({foo_select_action}, -1)
      case __temp_1
      when 0
        if __temp_3
          body
        end
      else
        baz
      end
      CODE
  end

  it "normalizes select with assign and question method" do
    assert_expand "select; when x = foo?; x + 1; end", <<-CODE
      __temp_1, __temp_2, __temp_3 = ::Channel.select({foo_select_action?}, 0)
      case __temp_1
      when 0
        x = __temp_2.as(typeof(foo?))
        x + 1
      else
        ::raise("BUG: invalid select index")
      end
      CODE
  end

  it "normalizes select with assign and bang method" do
    assert_expand "select; when x = foo!; x + 1; end", <<-CODE
      __temp_1, __temp_2, __temp_3 = ::Channel.select({foo_select_action!}, 0)
      case __temp_1
      when 0
        x = __temp_2.as(typeof(foo!))
        x + 1
      else
        ::raise("BUG: invalid select index")
      end
      CODE
  end
end
