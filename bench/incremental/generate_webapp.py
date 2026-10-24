#!/usr/bin/env python3
"""A generated project shaped like a web application rather than like widgets.

    python3 bench/incremental/generate_webapp.py DIR [controllers]

`generate_project.py` writes the project IV.3a's first table times: thirty
modules of ten small structs, one method each, no generics, no unions, no
macros. Issue #142 measured a real application of the same size rebuilding
28x slower than that table, and the difference is what the generated project
leaves out. So this writes what a web application has, at a size the issue's
application had (CONTROLLERS = 32: 131 files and 10,644 lines, against its
100 files and 10,713 lines):

  * per controller i, a model module whose struct is `derive serializable`;
  * a view module that embeds an EIY template (`Eiy.def_to_s`, a macro
    `run` at compile time), and the template;
  * a controller that keeps the models in a generic `Repo(T)` and answers a
    union, `String | NotFound`, taken apart with `case ... in`;
  * the generic repository, a config module whose macro reads
    `env("IYI_DEMO_MODE")`, and `main.iyi`, which prints one checksum.

`bench/edit_loop.py` times the loop on it.
"""
import os
import sys

CONTROLLERS = 32


def extra_methods(i):
    out = []
    for k in range(18):
        out.append(f"""
  def metric{k} : Int32
    base = (@id.to_i32 + {k}) * {i % 5 + 2}
    base = base + @name.size * {k % 4 + 1}
    base = base - @tags.size if base > {100 + k}
    base % {97 + k}
  end""")
    return "\n".join(out)


def extra_template(i):
    rows = []
    for k in range(6):
        rows.append(f"""<section class="s{k}">
<% items.each do |item| -%>
  <% if item.metric{k} > {k * 5} -%>
  <span><%= item.name %>: <%= item.metric{k} %> / <%= item.discounted(0.{k + 1}).round(2) %></span>
  <% end -%>
<% end -%>
</section>""")
    return "\n".join(rows) + "\n"


def extra_endpoints(i):
    out = []
    for k in range(5):
        out.append(f"""
pub def report{i}_{k}(limit : Int32) : String | NotFound
  repo = Repo(Item{i}).new
  sample{i}(limit).each {{ |item| repo.add(item.id, item) }}
  return NotFound.new({k}_i64) if repo.size == 0
  best = repo.all.max_by {{ |item| item.metric{k} }}
  picked = repo.all.select {{ |item| item.tagged?("t{k % 3}") }}
  "#{{best.name}}=#{{best.metric{k}}} of #{{picked.size}}"
end""")
    out.append(f"""
pub def reports{i} : Int32
  total = 0""")
    for k in range(5):
        out.append(f"""  case report{i}_{k}({k + 1})
  in String   then total = total + it.size
  in NotFound then total = total + 1
  end""")
    out.append("  total\nend")
    return "\n".join(out) + "\n"


def model(i):
    return f"""module web/models/m{i}

import std/json::{{JSON, ToJSON, serializable}}

pub struct Item{i}
  getter id : Int64
  getter name : String
  getter price : Float64
  getter tags : Array(String)
  getter note : String?

  def initialize(@id : Int64, @name : String, @price : Float64, @tags : Array(String), @note : String?)
  end

  derive serializable

  def score : Int32
    edit_point = 0
    ((@id.to_i32 * {3 + i % 7}) + @name.size * {5 + i % 11} + @tags.size + edit_point) % 1000
  end

  def describe : String
    note = @note
    suffix = note.nil? ? "" : " (#{{note}})"
    "#{{@name}} at #{{@price.round(2)}}#{{suffix}}"
  end

  def discounted(rate : Float64) : Float64
    @price * (1.0 - rate)
  end

  def tagged?(tag : String) : Bool
    @tags.includes?(tag)
  end
{extra_methods(i)}
end

pub def sample{i}(n : Int32) : Array(Item{i})
  items = [] of Item{i}
  n.times do |k|
    note = k.even? ? "even #{{k}}" : nil
    items << Item{i}.new(k.to_i64 + 1, "item-{i}-#{{k}}", (k * {i % 13 + 1}).to_f64 + 0.5, ["t#{{k % 3}}", "m{i}"], note)
  end
  items
end
"""


def view(i):
    return f"""module web/views/v{i}

import std/eiy::{{Eiy}}
import web/models/m{i}::{{Item{i}}}

pub class View{i}
  getter title : String
  getter items : Array(Item{i})

  def initialize(@title : String, @items : Array(Item{i}))
  end

  Eiy.def_to_s("v{i}.eiy")
end
"""


def template(i):
    return f"""<h1><%= title %></h1>
<ul>
<% items.each do |item| -%>
  <li id="item-<%= item.id %>"><%= item.describe %> score=<%= item.score %><% if item.tagged?("t0") %> [t0]<% end %></li>
<% end -%>
</ul>
<p>view {i}: <%= items.size %> items</p>
{extra_template(i)}"""


def controller(i):
    return f"""module web/controllers/c{i}

import std/json::{{JSON}}
import web/repo::{{Repo, NotFound}}
import web/models/m{i}::{{Item{i}, sample{i}}}
import web/views/v{i}::{{View{i}}}

pub def handle{i}(id : Int64) : String | NotFound
  repo = Repo(Item{i}).new
  sample{i}(6).each {{ |item| repo.add(item.id, item) }}
  found = repo.find(id)!
  page = View{i}.new("controller {i}", repo.all).to_s
  json = found.to_json
  "#{{page.size}}:#{{json.size}}:#{{found.score}}"
end

pub def checksum{i} : Int32
  total = reports{i}
  [1_i64, 3_i64, 99_i64].each do |id|
    case handle{i}(id)
    in String   then total = (total + it.size) % 100000
    in NotFound then total = (total + it.message.size) % 100000
    end
  end
  total
end
{extra_endpoints(i)}"""


REPO = """module web/repo

pub struct NotFound
  getter id : Int64

  def initialize(@id : Int64)
  end
end

impl Error for NotFound
  def message : String
    "no record #{id}"
  end
end

pub class Repo(T)
  @items : Hash(Int64, T)

  def initialize
    @items = {} of Int64 => T
  end

  def add(id : Int64, item : T) : Nil
    @items[id] = item
  end

  def find(id : Int64) : T | NotFound
    item = @items[id]?
    return NotFound.new(id) if item.nil?
    item
  end

  def all : Array(T)
    @items.values
  end

  def size : Int32
    @items.size
  end
end
"""

CONFIG = """module web/config

pub def mode : String
  {{ env("IYI_DEMO_MODE") || "dev" }}
end
"""


def main(n):
    lines = ["module main", "", "import web/config"]
    lines += [f"import web/controllers/c{i}" for i in range(n)]
    lines += ["", "total = 0"]
    for i in range(n):
        lines.append(f"total = (total + Web::Controllers::C{i}.checksum{i}) % 1000000")
    lines += ["", 'puts "#{Web::Config.mode} #{total}"', ""]
    return "\n".join(lines)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def generate(root, n):
    write(os.path.join(root, "web", "repo.iyi"), REPO)
    write(os.path.join(root, "web", "config.iyi"), CONFIG)
    for i in range(n):
        write(os.path.join(root, "web", "models", f"m{i}.iyi"), model(i))
        write(os.path.join(root, "web", "views", f"v{i}.iyi"), view(i))
        write(os.path.join(root, "web", "views", f"v{i}.eiy"), template(i))
        write(os.path.join(root, "web", "controllers", f"c{i}.iyi"), controller(i))
    write(os.path.join(root, "main.iyi"), main(n))


if __name__ == "__main__":
    generate(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else CONTROLLERS)
