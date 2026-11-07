" Run from any directory: vim -Nu NONE -i NONE -n -es -S editors/vim/test/syntax.vim
let s:runtime = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' . fnameescape(s:runtime)
filetype plugin on
syntax enable
new fixture.iyi
call assert_equal('iyi', &filetype)
call assert_equal(2, &l:shiftwidth)
call assert_equal('# %s', &l:commentstring)

function! s:Check(text, needle, expected) abort
  call append(line('$'), a:text)
  let l:row = line('$')
  let l:start = stridx(a:text, a:needle) + 1
  call assert_true(l:start > 0, 'missing test text: ' . a:needle)
  for l:col in range(l:start, l:start + strlen(a:needle) - 1)
    call assert_equal(a:expected, synIDattr(synID(l:row, l:col, 1), 'name'), a:text . ' column ' . l:col)
  endfor
endfunction

call s:Check('pub def self.read(path : String)', 'read', 'iyiFunction')
call s:Check('def HTTP::Client.get', 'get', 'iyiFunction')
call s:Check('def []=(index, value)', '[]=', 'iyiFunction')
call s:Check('def value=(value)', 'value=', 'iyiFunction')
call s:Check('def ready?', 'ready?', 'iyiFunction')
call s:Check('def read!', '!', '')
call s:Check('fun puts(s : UInt8*)', 'puts', 'iyiFunction')
call s:Check('x = Foo::Bar', 'Bar', 'iyiType')
call s:Check('x = Foo::Bar', '::', '')
call s:Check('x = :ready?', ':ready?', 'iyiSymbol')
call s:Check('x = :"hello world"', ':"hello world"', 'iyiQuotedSymbol')
for s:number in ['0xDEAD_beef_u64', '0b1010_u8', '0o755', '1_000_i128', '1.5e-10_f64', '2e1_0']
  call s:Check('x = ' . s:number, s:number, 'iyiNumber')
endfor
call s:Check('x = 1..3', '..', '')
call s:Check("x = '#'", "'#'", 'iyiCharacter')
call s:Check("x = '\\n'", '\n', 'iyiEscape')
call s:Check('#{ TODO comment', 'comment', 'iyiComment')
call s:Check('# TODO', 'TODO', 'iyiTodo')
for s:word in ['private', 'annotation', 'pointerof', 'as?', 'is_a?', 'nil?', 'responds_to?', 'forall', 'group', 'defer']
  call s:Check('x ' . s:word, s:word, 'iyiKeyword')
endfor
call s:Check('x = nil', 'nil', 'iyiBoolean')
call s:Check('x = nil_value', 'nil_value', '')
call s:Check('x = is_a?thing', 'is_a?thing', '')
call s:Check('x = __FILE__', '__FILE__', 'iyiMagic')
call s:Check('{% if flag?(:linux) %}', '{%', 'iyiMacroDelimiter')
call s:Check('x = "#{ {key: 1} } after"', '1', 'iyiNumber')
call s:Check('x = "#{ {key: 1} } after"', 'after', 'iyiString')
call s:Check('x = "#{ "nested #{1}" } after"', 'after', 'iyiString')
call s:Check('x = "\#{literal}"', 'literal}', 'iyiString')
for s:pair in [['(', ')'], ['[', ']'], ['{', '}'], ['<', '>'], ['|', '|']]
  call s:Check('x = %Q' . s:pair[0] . '#{1} text' . s:pair[1], '1', 'iyiNumber')
  call s:Check('x = %q' . s:pair[0] . '#{1} text' . s:pair[1], '#{1}', 'iyiRawPercentString')
  call s:Check('x = %Q' . s:pair[0] . 'text' . s:pair[1] . '; 42', '42', 'iyiNumber')
  call s:Check('x = %q' . s:pair[0] . 'text' . s:pair[1] . '; 42', '42', 'iyiNumber')
endfor
call s:Check('x = %w(one two)', 'two', 'iyiRawPercentString')
call s:Check('x = %i(one two)', 'two', 'iyiRawPercentString')
call s:Check('x = %r{[a-z]+}', '[a-z]+', 'iyiPercentString')
call s:Check('x = %(outer (inner) after)', 'after', 'iyiPercentString')
call s:Check('x = %q{outer {inner} after}', 'after', 'iyiRawPercentString')
call s:Check('x = %q{raw\}; 42', '42', 'iyiNumber')
call s:Check('x = `echo #{1}`', '1', 'iyiNumber')
call s:Check('x = `echo text`; 42', '42', 'iyiNumber')
call append(line('$'), ['x = <<-TEXT', '  hello #{1}', '  TEXT', 'x = 2'])
call assert_equal('iyiNumber', synIDattr(synID(line('$') - 2, 11, 1), 'name'))
call assert_equal('iyiNumber', synIDattr(synID(line('$'), 5, 1), 'name'))
call append(line('$'), ["x = <<-'RAW'", '  hello #{1}', '  RAW', 'x = 2'])
call assert_equal('iyiRawHeredoc', synIDattr(synID(line('$') - 2, 11, 1), 'name'))
call assert_equal('iyiNumber', synIDattr(synID(line('$'), 5, 1), 'name'))

if !empty(v:errors)
  for s:error in v:errors
    echom s:error
  endfor
  cquit
endif
qa!
