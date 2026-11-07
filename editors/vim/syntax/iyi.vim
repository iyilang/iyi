" Author: Priit Tark
" SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
" Lexical highlighting based on src/compiler/iyi/syntax/lexer.cr and token.cr.
if exists('b:current_syntax')
  finish
endif

syn case match
" Predicate suffixes belong to identifiers; ! is iyi's propagation operator.
syn iskeyword @,48-57,_,192-255,?
syn keyword iyiKeyword module import pub end if elsif else unless while until
syn keyword iyiKeyword def macro fun nextgroup=iyiReceiver,iyiFunction skipwhite
syn keyword iyiKeyword case when in then do begin rescue ensure return break next
syn keyword iyiKeyword yield struct class trait impl for forall enum lib
syn keyword iyiKeyword abstract getter setter property type alias extend include
syn keyword iyiKeyword require group spawn defer select of as sizeof typeof not
syn keyword iyiKeyword alignof annotation asm instance_alignof instance_sizeof
syn keyword iyiKeyword offsetof out pointerof private protected uninitialized
syn keyword iyiKeyword union using verbatim with
syn keyword iyiBoolean true false nil
syn keyword iyiSelf self super
syn keyword iyiKeyword as? is_a? nil? responds_to?
syn match iyiType "\<[A-Z][A-Za-z0-9_]*\>"
syn match iyiFunction "\%([a-z_][A-Za-z0-9_]*[?=]\?\|\[\][?=]\?\|\*\*\|//\|<=>\|===\|[=!<>]=\|<<\|>>\|[+*/%&|^~<>-]\)" contained
" A receiver includes its dot so nextgroup reaches the actual method name.
syn match iyiReceiver "\%([a-z_][A-Za-z0-9_]*\|\%(::\)\?[A-Z][A-Za-z0-9_]*\%(::[A-Z][A-Za-z0-9_]*\)*\)\." contained transparent contains=iyiSelf,iyiType nextgroup=iyiFunction
syn match iyiNumber "\<\%(0x[0-9A-Fa-f][0-9A-Fa-f_]*\|0o[0-7][0-7_]*\|0b[01][01_]*\|\d[0-9_]*\%(\.\d[0-9_]*\)\?\%([eE][+-]\?\d[0-9_]*\)\?\)\%(_\?\%([iu]\%(8\|16\|32\|64\|128\)\|f\%(32\|64\)\)\)\?\>"
" Do not mistake the second colon of Foo::Bar for a symbol prefix.
syn match iyiSymbol "\%(:\)\@<!:[a-zA-Z_][A-Za-z0-9_]*[?!]\?"
syn region iyiQuotedSymbol start=+\%(:\)\@<!:"+ skip=+\\.+ end=+"+ contains=iyiEscape
syn match iyiInstanceVariable "@\{1,2}[a-z_][A-Za-z0-9_]*"
syn match iyiMagic "\<__\%(DIR\|FILE\|LINE\|END_LINE\)__\>"
syn match iyiMacroDelimiter "{{\|}}\|{%\|%}"
syn keyword iyiTodo TODO FIXME XXX NOTE contained
" Outside a string, #{ is a comment too.
syn match iyiComment "#.*$" contains=iyiTodo,@Spell
syn region iyiCharacter start=+'+ skip=+\\.+ end=+'+ oneline contains=iyiEscape
syn region iyiString start=+"+ skip=+\\.+ end=+"+ contains=iyiEscape,iyiInterpolation,@Spell
syn region iyiCommand start=+`+ skip=+\\.+ end=+`+ contains=iyiEscape,iyiInterpolation
syn match iyiEscape "\\." contained
syn cluster iyiExpression contains=iyiKeyword,iyiBoolean,iyiSelf,iyiType,iyiNumber,iyiSymbol,iyiQuotedSymbol,iyiInstanceVariable,iyiMagic,iyiMacroDelimiter,iyiComment,iyiCharacter,iyiString,iyiCommand
syn region iyiInterpolation matchgroup=iyiInterpolationDelimiter start="#{" end="}" contained contains=@iyiExpression,iyiInterpolationBrace
syn region iyiInterpolationBrace start="{" end="}" contained transparent contains=@iyiExpression,iyiInterpolationBrace
" Percent literals balance their own delimiter. q/w/i are non-interpolating.
for s:pair in [['(', ')'], ['[', ']'], ['{', '}'], ['<', '>'], ['|', '|']]
  let s:open = escape(s:pair[0], '[~')
  let s:close = escape(s:pair[1], '[~')
  let s:id = index(['(', '[', '{', '<', '|'], s:pair[0])
  let s:full = 'iyiPercentNest' . s:id
  let s:raw = 'iyiRawPercentNest' . s:id
  let s:q = 'iyiQuotePercentNest' . s:id
  execute 'syn region iyiPercentString matchgroup=iyiStringDelimiter start=+%[QWrx]\?' . s:open . '+ skip=+\\.+ end=+' . s:close . '+ contains=iyiEscape,iyiInterpolation,' . s:full . ',@Spell'
  execute 'syn region iyiRawPercentString matchgroup=iyiStringDelimiter start=+%[wi]' . s:open . '+ skip=+\\.+ end=+' . s:close . '+ contains=' . s:raw . ',@Spell'
  execute 'syn region iyiRawPercentString matchgroup=iyiStringDelimiter start=+%q' . s:open . '+ end=+' . s:close . '+ contains=' . s:q . ',@Spell'
  if s:pair[0] !=# '|'
    execute 'syn region ' . s:full . ' start=+' . s:open . '+ skip=+\\.+ end=+' . s:close . '+ contained transparent contains=iyiEscape,iyiInterpolation,' . s:full . ',@Spell'
    execute 'syn region ' . s:raw . ' start=+' . s:open . '+ skip=+\\.+ end=+' . s:close . '+ contained transparent contains=' . s:raw . ',@Spell'
    execute 'syn region ' . s:q . ' start=+' . s:open . '+ end=+' . s:close . '+ contained transparent contains=' . s:q . ',@Spell'
  endif
endfor
unlet s:pair s:open s:close s:id s:full s:raw s:q
syn cluster iyiExpression add=iyiPercentString,iyiRawPercentString,iyiHeredoc,iyiRawHeredoc
" Capture the terminator rather than treating heredoc contents as code.
syn region iyiHeredoc start=+<<-\z([A-Za-z_][A-Za-z0-9_]*\)+ end=+^\s*\z1$+ contains=iyiEscape,iyiInterpolation,@Spell
syn region iyiRawHeredoc start=+<<-'\z([A-Za-z_][A-Za-z0-9_]*\)'+ end=+^\s*\z1$+ contains=@Spell
syn sync fromstart

hi def link iyiKeyword Keyword
hi def link iyiBoolean Boolean
hi def link iyiSelf Identifier
hi def link iyiType Type
hi def link iyiFunction Function
hi def link iyiNumber Number
hi def link iyiSymbol Constant
hi def link iyiQuotedSymbol Constant
hi def link iyiInstanceVariable Identifier
hi def link iyiMagic PreProc
hi def link iyiMacroDelimiter PreProc
hi def link iyiComment Comment
hi def link iyiTodo Todo
hi def link iyiString String
hi def link iyiCommand String
hi def link iyiCharacter Character
hi def link iyiStringDelimiter String
hi def link iyiPercentString String
hi def link iyiRawPercentString String
hi def link iyiHeredoc String
hi def link iyiRawHeredoc String
hi def link iyiEscape SpecialChar
hi def link iyiInterpolationDelimiter Delimiter

let b:current_syntax = 'iyi'
