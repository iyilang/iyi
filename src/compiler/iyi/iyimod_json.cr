# iyi: a module's API surface as JSON — AI_FIRST.md §2 item 1, and the
# sentence it serves is III.7's: "A model writing iyi code needs exact
# signatures; given prose it invents them."
#
# The object is the artifact's `Exports`, verbatim: nothing here is
# computed, summarised or prettified, because the value of the endpoint is
# that it cannot drift from what the compiler checks. Each signature also
# carries `rendered`, the same one-line `def …` a human reads in
# `mod dump --declarations` — a model quoting a signature should be able
# to quote the spelling the compiler would accept.
#
# `interface_hash` is deliberately in the object: it is the cache key a
# consumer of this API wants (IV.3's interface hash — when it is unchanged,
# everything else in the object is too).
require "json"

module Iyi::IyiMod
  def self.api_json(artifact : Artifact, json : JSON::Builder) : Nil
    json.object do
      json.field "module", artifact.module_name
      json.field "interface_hash", artifact.hashes.interface
      json.field "functions" do
        json.array do
          artifact.exports.functions.each { |signature| api_signature(signature, json) }
        end
      end
      json.field "types" do
        json.array do
          artifact.exports.types.each { |declaration| api_type(declaration, json) }
        end
      end
      # The `pub` ones, each as its line and its doc: a macro takes syntax
      # and has no types to list. Absent, as a type's were, `mod context
      # --json` grounded an edit with no `Eiy.embed` in it.
      macros = IyiMod.exported_macros(artifact)
      json.field "macros" { api_macros(macros, json) } unless macros.empty?
      json.field "impls" do
        json.array do
          artifact.exports.impls.each do |entry|
            json.object do
              json.field "trait", entry.trait_name
              json.field "type", entry.type_name
              unless entry.trait_arguments.empty?
                json.field "trait_arguments" { json.array { entry.trait_arguments.each { |a| json.string a } } }
              end
            end
          end
        end
      end
    end
  end

  private def self.api_signature(signature : Signature, json : JSON::Builder) : Nil
    json.object do
      json.field "name", signature.name
      json.field "receiver", signature.receiver unless signature.receiver.empty?
      json.field "parameters" { json.array { signature.parameters.each { |p| json.string p } } }
      json.field "block", signature.block_parameter unless signature.block_parameter.empty?
      json.field "returns", signature.return_type unless signature.return_type.empty?
      unless signature.free_variables.empty?
        json.field "free_variables" { json.array { signature.free_variables.each { |v| json.string v } } }
      end
      json.field "required", true if signature.required
      json.field "visibility", signature.visibility unless signature.visibility.empty?
      json.field "doc", signature.doc unless signature.doc.empty?
      json.field "rendered", IyiMod.render_signature(signature)
    end
  end

  private def self.api_macros(sources : Array(String), json : JSON::Builder) : Nil
    json.array do
      sources.each do |source|
        json.object do
          json.field "name", IyiMod.macro_name(source)
          doc = IyiMod.macro_doc(source)
          json.field "doc", doc unless doc.empty?
          json.field "rendered", IyiMod.macro_line(source)
        end
      end
    end
  end

  private def self.api_type(declaration : TypeDecl, json : JSON::Builder) : Nil
    json.object do
      json.field "name", declaration.name
      json.field "kind", declaration.kind
      json.field "doc", declaration.doc unless declaration.doc.empty?
      json.field "visibility", declaration.visibility
      unless declaration.type_parameters.empty?
        json.field "type_parameters" { json.array { declaration.type_parameters.each { |p| json.string p } } }
      end
      unless declaration.assoc_types.empty?
        json.field "assoc_types" { json.array { declaration.assoc_types.each { |a| json.string a } } }
      end
      unless declaration.supertraits.empty?
        json.field "supertraits" { json.array { declaration.supertraits.each { |s| json.string s } } }
      end
      json.field "alias_of", declaration.value unless declaration.value.empty?
      unless declaration.fields.empty?
        json.field "fields" do
          json.array do
            declaration.fields.each do |(name, type, default)|
              json.object do
                json.field "name", name
                json.field "type", type
                json.field "default", default unless default.empty?
              end
            end
          end
        end
      end
      unless declaration.members.empty?
        json.field "members" do
          json.array do
            declaration.members.each do |(name, value)|
              json.object do
                json.field "name", name
                json.field "value", value unless value.empty?
              end
            end
          end
        end
      end
      unless declaration.methods.empty?
        json.field "methods" { json.array { declaration.methods.each { |m| api_signature(m, json) } } }
      end
      json.field "macros" { api_macros(declaration.macros, json) } unless declaration.macros.empty?
      unless declaration.types.empty?
        json.field "types" { json.array { declaration.types.each { |t| api_type(t, json) } } }
      end
    end
  end
end
