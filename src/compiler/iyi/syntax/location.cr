# A location of an `ASTnode`, including its filename, line number and column number.
class Iyi::Location
  include Comparable(self)

  getter line_number
  getter column_number
  getter filename

  # iyi: the `.iyimod` this build read the node out of, or nil for a node of
  # a file it read. A body that travelled in an artifact is located in its
  # module's source (`IyiMod::SourcePosition`), which is what a person and a
  # macro's `@caller` see; this is what says it came from the artifact all
  # the same, for every decision about *which file this build read*: import
  # edges, file-private names, and the refusals a module's own build already
  # made of its own source (`read_from`).
  getter artifact : String?

  def initialize(@filename : String | VirtualFile | Nil, @line_number : Int32, @column_number : Int32,
                 @artifact : String? = nil)
  end

  # iyi: the `artifact` of `expanded_location`: what a node a macro wrote
  # was read out of is what the call that expanded it was.
  def original_artifact : String?
    expanded_location.try &.artifact
  end

  # iyi: the file this build read the node out of: the artifact, for a node
  # read from one, and the filename otherwise. The question a decision about
  # the build asks, where `filename` is the one a person is shown.
  def read_from : String | VirtualFile | Nil
    filename = @filename
    filename.is_a?(String) ? (@artifact || filename) : filename
  end

  # iyi: `read_from` of `expanded_location`, as `original_filename` is its
  # filename.
  def original_read_from : String?
    original_artifact || original_filename
  end

  # Returns a location from a string representation. Used by compiler tools like
  # `context` and `implementations`.
  def self.parse(cursor : String, *, expand : Bool = false) : self
    file_and_line, _, col = cursor.rpartition(':')
    file, _, line = file_and_line.rpartition(':')

    raise ArgumentError.new "cursor location must be file:line:column" if file.empty? || line.empty? || col.empty?

    file = File.expand_path(file) if expand

    line_number = line.to_i? || 0
    if line_number <= 0
      raise ArgumentError.new "line must be a positive integer, not #{line}"
    end

    column_number = col.to_i? || 0
    if column_number <= 0
      raise ArgumentError.new "column must be a positive integer, not #{col}"
    end

    new(file, line_number, column_number)
  end

  # Returns the directory name of this location's filename. If
  # the filename is a VirtualFile, this is invoked on its expanded
  # location.
  def dirname : String?
    original_filename.try { |filename| File.dirname(filename) }
  end

  # Returns the Location whose filename is a String, not a VirtualFile,
  # traversing virtual file expanded locations.
  def expanded_location
    case filename = @filename
    when String
      self
    when VirtualFile
      filename.expanded_location.try &.expanded_location
    else
      nil
    end
  end

  # Returns the Location whose filename is a String, not a VirtualFile,
  # traversing virtual file expanded locations leading to the original user source code
  def macro_location
    case filename = @filename
    when String
      self
    when VirtualFile
      filename.macro.location.try(&.macro_location)
    else
      nil
    end
  end

  # Returns the filename of the `expanded_location`
  def original_filename
    expanded_location.try &.filename.as?(String)
  end

  def between?(min, max)
    return false unless min && max

    min <= self && self <= max
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end

  def to_s(io : IO) : Nil
    io << filename << ':' << line_number << ':' << column_number
  end

  def pretty_print(pp)
    pp.text to_s
  end

  def <=>(other)
    self_file = @filename
    other_file = other.filename
    if self_file.is_a?(String) && other_file.is_a?(String) && Location.same_file?(self_file, other_file)
      {@line_number, @column_number} <=> {other.line_number, other.column_number}
    else
      nil
    end
  end

  # iyi: whether two filenames name one file. On POSIX that is string
  # equality. On Windows a file has spellings: an imported module's is
  # `File.join(root, "calc/lexer.iyi")`, which keeps the module path's `/`
  # inside a backslashed root, while the same file opened in an editor is
  # all backslashes — and the filesystem ignores case besides. Comparing
  # the strings, every location in an importer's compile was unordered
  # against the cursor, so the language server's references, call
  # hierarchy and implementations never reached a file nobody had opened
  # (step 32 of `bench/lsp_session.py`, the first time it ran there).
  # Byte by byte, so asking allocates nothing: it is asked for every node
  # a cursor visitor walks.
  def self.same_file?(a : String, b : String) : Bool
    return true if a == b
    {% if flag?(:win32) %}
      return false unless a.bytesize == b.bytesize
      a.bytesize.times do |index|
        x = a.to_unsafe[index]
        y = b.to_unsafe[index]
        next if x == y
        x = '/'.ord.to_u8 if x == '\\'.ord.to_u8
        y = '/'.ord.to_u8 if y == '\\'.ord.to_u8
        x = x + 32 if 'A'.ord <= x <= 'Z'.ord
        y = y + 32 if 'A'.ord <= y <= 'Z'.ord
        return false unless x == y
      end
      true
    {% else %}
      false
    {% end %}
  end

  def equals?(other)
    return false unless (@filename || "") == (other.filename || "")
    return false unless @line_number == other.line_number
    return false unless @column_number == other.column_number
    true
  end

  # Returns the number of lines between start and finish locations.
  def self.lines(start, finish)
    return unless start && finish && start.filename == finish.filename
    start, finish = finish, start if finish < start

    finish.line_number - start.line_number + 1
  end
end
