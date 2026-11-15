//// Tests for the syntax tree walk. A recording visitor writes down what each
//// hook sees: definitions by name, statements by kind, and the names of
//// variables, pattern variables and named types. The reach test puts a
//// uniquely named one of those in every position that holds a node, so a
//// child the walk forgets, or one it walks out of order, changes the
//// recording.

import glance
import gleam/dict
import gleam/list
import gleam/string
import grice/visit

// Reach

const reach_source =
  "
import wibble/imported.{type ImportedType, imported_value as alias_value}

@deprecated(definition_attribute_argument)
pub type CustomType(type_parameter) {
  @deprecated(variant_attribute_argument)
  VariantOne(VariantFieldOne, label: VariantFieldTwo)
  VariantTwo
}

type AliasOne =
  fn(FunctionParameter, #(TupleElement, type_variable)) -> FunctionReturn

const constant_one: ConstantAnnotation = constant_value

@external(erlang, \"attribute_module\", \"attribute_function\")
pub fn statements(
  labelled parameter_name: ParameterAnnotation,
  unannotated,
) -> ReturnAnnotation {
  use use_pattern: UseAnnotation, use_second <- use_function(use_argument)
  let let_pattern: LetAnnotation(LetArgument) = let_value
  let assert assert_pattern: _ = assert_value as assert_message
  assert assert_expression as assert_statement_message
  expression_statement
}

fn expressions() {
  -negate_int_operand
  !negate_bool_operand
  { block_statement }
  panic as panic_message
  todo as todo_message
  #(tuple_first, tuple_second)
  [list_first, list_second, ..list_rest]
  fn(fn_parameter: FnAnnotation, fn_unannotated) -> FnReturn { fn_body }
  Record(..update_record, update_label: update_value, update_shorthand:)
  access_container.access_label
  call_function(call_unlabelled, call_label: call_labelled, call_shorthand:)
  index_tuple.0
  capture_function(capture_before, _, capture_after)
  <<segment_value:size(segment_size), 1:8>>
  case case_subject_one, case_subject_two {
    clause_one_a, clause_one_b | clause_two_a, clause_two_b if clause_guard ->
      clause_body
  }
  binary_left + binary_right
  pipe_subject |> echo
  echo echo_value as echo_message
  1
  1.0
  \"string\"
}

fn patterns() {
  case pattern_subject {
    1 -> int_body
    1.0 -> float_body
    \"string\" -> string_body
    _discarded -> discard_body
    #(tuple_pattern_first, tuple_pattern_second) -> tuple_body
    [list_pattern_first, ..list_pattern_tail] -> list_body
    inner_pattern as outer_name -> as_body
    \"prefix\" as prefix_name <> rest_name -> concatenate_body
    <<segment_pattern:size(size_name), _:bytes>> -> bit_array_body
    Constructor(constructor_unlabelled, label: constructor_labelled, shorthand:, ..) ->
      constructor_body
  }
}
"

pub fn module_reaches_every_child_in_source_order_test() {
  assert walk(reach_source)
    == [
      "import:wibble/imported",
      // Custom type: the field types, not the attribute arguments.
      "custom_type:CustomType",
      "t:VariantFieldOne",
      "t:VariantFieldTwo",
      // Type alias: a function type's parameters, then its return type.
      "alias:AliasOne",
      "t:FunctionParameter",
      "t:TupleElement",
      "t:FunctionReturn",
      "const:constant_one",
      "t:ConstantAnnotation",
      "e:constant_value",
      // Statements, after the parameter and return annotations.
      "fn:statements",
      "t:ParameterAnnotation",
      "t:ReturnAnnotation",
      "s:use",
      "p:use_pattern",
      "t:UseAnnotation",
      "p:use_second",
      "e:use_function",
      "e:use_argument",
      "s:let",
      "p:let_pattern",
      "t:LetAnnotation",
      "t:LetArgument",
      "e:let_value",
      "s:let_assert",
      "p:assert_pattern",
      "e:assert_value",
      "e:assert_message",
      "s:assert",
      "e:assert_expression",
      "e:assert_statement_message",
      "s:expression",
      "e:expression_statement",
      "exit:statements",
      // Expressions.
      "fn:expressions",
      "s:expression",
      "e:negate_int_operand",
      "s:expression",
      "e:negate_bool_operand",
      "s:expression",
      "s:expression",
      "e:block_statement",
      "s:expression",
      "e:panic_message",
      "s:expression",
      "e:todo_message",
      "s:expression",
      "e:tuple_first",
      "e:tuple_second",
      "s:expression",
      "e:list_first",
      "e:list_second",
      "e:list_rest",
      "s:expression",
      "t:FnAnnotation",
      "t:FnReturn",
      "s:expression",
      "e:fn_body",
      "s:expression",
      "e:update_record",
      "e:update_value",
      "s:expression",
      "e:access_container",
      "s:expression",
      "e:call_function",
      "e:call_unlabelled",
      "e:call_labelled",
      "s:expression",
      "e:index_tuple",
      "s:expression",
      "e:capture_function",
      "e:capture_before",
      "e:capture_after",
      "s:expression",
      "e:segment_value",
      "e:segment_size",
      "s:expression",
      "e:case_subject_one",
      "e:case_subject_two",
      "p:clause_one_a",
      "p:clause_one_b",
      "p:clause_two_a",
      "p:clause_two_b",
      "e:clause_guard",
      "e:clause_body",
      "s:expression",
      "e:binary_left",
      "e:binary_right",
      "s:expression",
      "e:pipe_subject",
      "s:expression",
      "e:echo_value",
      "e:echo_message",
      "s:expression",
      "s:expression",
      "s:expression",
      "exit:expressions",
      // Patterns. A bit array pattern's size isn't walked.
      "fn:patterns",
      "s:expression",
      "e:pattern_subject",
      "e:int_body",
      "e:float_body",
      "e:string_body",
      "e:discard_body",
      "p:tuple_pattern_first",
      "p:tuple_pattern_second",
      "e:tuple_body",
      "p:list_pattern_first",
      "p:list_pattern_tail",
      "e:list_body",
      "p:inner_pattern",
      "e:as_body",
      "e:concatenate_body",
      "p:segment_pattern",
      "e:bit_array_body",
      "p:constructor_unlabelled",
      "p:constructor_labelled",
      "e:constructor_body",
      "exit:patterns",
    ]
}

// Every expression, pattern and type node of the reach source calls its
// hook, wrappers and unnamed leaves included, and every expression its exit
// hook too. The counts are by constructor.
pub fn module_calls_a_hook_on_every_node_test() {
  let assert Ok(module) = glance.module(reach_source)
  let seen =
    visit.new()
    |> visit.on_expression(constructor_as("e:"))
    |> visit.on_pattern(constructor_as("p:"))
    |> visit.on_type(constructor_as("t:"))
    |> visit.module(module, from: [], with: _)
  let exits =
    visit.new()
    |> visit.on_expression_exit(constructor_as("e:"))
    |> visit.module(module, from: [], with: _)
  assert count(seen)
    == [
      #("e:BinaryOperator", 2),
      #("e:BitString", 1),
      #("e:Block", 1),
      #("e:Call", 2),
      #("e:Case", 2),
      #("e:Echo", 2),
      #("e:FieldAccess", 1),
      #("e:Float", 1),
      #("e:Fn", 1),
      #("e:FnCapture", 1),
      #("e:Int", 2),
      #("e:List", 1),
      #("e:NegateBool", 1),
      #("e:NegateInt", 1),
      #("e:Panic", 1),
      #("e:RecordUpdate", 1),
      #("e:String", 1),
      #("e:Todo", 1),
      #("e:Tuple", 1),
      #("e:TupleIndex", 1),
      #("e:Variable", 52),
      #("p:PatternAssignment", 1),
      #("p:PatternBitString", 1),
      #("p:PatternConcatenate", 1),
      #("p:PatternDiscard", 2),
      #("p:PatternFloat", 1),
      #("p:PatternInt", 1),
      #("p:PatternList", 1),
      #("p:PatternString", 1),
      #("p:PatternTuple", 1),
      #("p:PatternVariable", 16),
      #("p:PatternVariant", 1),
      #("t:FunctionType", 1),
      #("t:HoleType", 1),
      #("t:NamedType", 13),
      #("t:TupleType", 1),
      #("t:VariableType", 1),
    ]
  assert count(exits)
    == list.filter(count(seen), fn(entry) { string.starts_with(entry.0, "e:") })
}

pub fn pattern_and_type_hooks_see_wrappers_and_leaves_test() {
  let assert Ok(module) =
    glance.module(
      "fn f(x: fn(a, _) -> #(B(c), d)) {\n  let Ctor(#(y, _), [z]) = x\n}",
    )
  let seen =
    visit.new()
    |> visit.on_pattern(constructor_as("p:"))
    |> visit.on_type(constructor_as("t:"))
    |> visit.module(module, from: [], with: _)
  assert list.reverse(seen)
    == [
      "t:FunctionType", "t:VariableType", "t:HoleType", "t:TupleType",
      "t:NamedType", "t:VariableType", "t:VariableType", "p:PatternVariant",
      "p:PatternTuple", "p:PatternVariable", "p:PatternDiscard", "p:PatternList",
      "p:PatternVariable",
    ]
}

// Order

pub fn module_walks_definitions_in_source_order_across_kinds_test() {
  let source =
    "
pub fn first() { 1 }
import first_import
const first_constant = 1
type FirstType { FirstType }
pub fn second() { 2 }
type FirstAlias = Int
import second_import
const second_constant = 2
type SecondType { SecondType }
type SecondAlias = Int
pub fn third() { 3 }
"
  let definitions =
    walk(source)
    |> list.filter(fn(seen) {
      !string.starts_with(seen, "s:")
      && !string.starts_with(seen, "t:")
      && !string.starts_with(seen, "exit:")
    })
  assert definitions
    == [
      "fn:first", "import:first_import", "const:first_constant",
      "custom_type:FirstType", "fn:second", "alias:FirstAlias",
      "import:second_import", "const:second_constant", "custom_type:SecondType",
      "alias:SecondAlias", "fn:third",
    ]
}

pub fn module_runs_enter_hooks_before_children_and_exit_hooks_after_test() {
  let assert Ok(module) =
    glance.module("fn outer() { callee(fn() { inner }) }\nfn next() { last }")
  let visitor =
    visit.new()
    |> visit.on_function(fn(seen, function) {
      ["enter " <> function.definition.name, ..seen]
    })
    |> visit.on_function_exit(fn(seen, function) {
      ["exit " <> function.definition.name, ..seen]
    })
    |> visit.on_expression(fn(seen, expression) {
      ["enter " <> describe(expression), ..seen]
    })
    |> visit.on_expression_exit(fn(seen, expression) {
      ["exit " <> describe(expression), ..seen]
    })
  assert list.reverse(visit.module(module, from: [], with: visitor))
    == [
      "enter outer", "enter call", "enter callee", "exit callee", "enter fn",
      "enter inner", "exit inner", "exit fn", "exit call", "exit outer",
      "enter next", "enter last", "exit last", "exit next",
    ]
}

pub fn hooks_of_one_kind_run_in_the_order_added_test() {
  let assert Ok(module) = glance.module("fn f() { first\n second }")
  let record = fn(tag) {
    fn(seen, expression) { [tag <> describe(expression), ..seen] }
  }
  let visitor =
    visit.new()
    |> visit.on_expression(record("a:"))
    |> visit.on_expression(record("b:"))
  assert list.reverse(visit.module(module, from: [], with: visitor))
    == ["a:first", "b:first", "a:second", "b:second"]
}

pub fn expression_walks_a_sub_tree_on_its_own_test() {
  let assert Ok(module) =
    glance.module(
      "fn f(x: Outside) { outside\n inner(#(a, fn(b: Inside) { c })) }",
    )
  let assert [glance.Definition(definition: function, ..)] = module.functions
  let assert [_, glance.Expression(expression)] = function.body
  let seen = visit.expression(expression, from: [], with: recorder())
  assert list.reverse(seen)
    == ["e:inner", "e:a", "t:Inside", "s:expression", "e:c"]
}

pub fn new_visitor_returns_the_accumulator_unchanged_test() {
  let assert Ok(module) = glance.module(reach_source)
  assert visit.module(module, from: 42, with: visit.new()) == 42
}

// Helpers

fn walk(source: String) -> List(String) {
  let assert Ok(module) = glance.module(source)
  list.reverse(visit.module(module, from: [], with: recorder()))
}

// A visitor that records, newest first, each definition, each statement's
// kind, each function exit, and the names of variables, pattern variables
// and named types.
fn recorder() -> visit.Visitor(List(String)) {
  visit.new()
  |> visit.on_import(fn(seen, import_) {
    ["import:" <> import_.definition.module, ..seen]
  })
  |> visit.on_custom_type(fn(seen, custom_type) {
    ["custom_type:" <> custom_type.definition.name, ..seen]
  })
  |> visit.on_type_alias(fn(seen, type_alias) {
    ["alias:" <> type_alias.definition.name, ..seen]
  })
  |> visit.on_constant(fn(seen, constant) {
    ["const:" <> constant.definition.name, ..seen]
  })
  |> visit.on_function(fn(seen, function) {
    ["fn:" <> function.definition.name, ..seen]
  })
  |> visit.on_function_exit(fn(seen, function) {
    ["exit:" <> function.definition.name, ..seen]
  })
  |> visit.on_statement(fn(seen, statement) {
    let kind = case statement {
      glance.Use(..) -> "use"
      glance.Assignment(kind: glance.Let, ..) -> "let"
      glance.Assignment(kind: glance.LetAssert(..), ..) -> "let_assert"
      glance.Assert(..) -> "assert"
      glance.Expression(..) -> "expression"
    }
    ["s:" <> kind, ..seen]
  })
  |> visit.on_expression(fn(seen, expression) {
    case expression {
      glance.Variable(name:, ..) -> ["e:" <> name, ..seen]
      _ -> seen
    }
  })
  |> visit.on_pattern(fn(seen, pattern) {
    case pattern {
      glance.PatternVariable(name:, ..) -> ["p:" <> name, ..seen]
      _ -> seen
    }
  })
  |> visit.on_type(fn(seen, type_) {
    case type_ {
      glance.NamedType(name:, ..) -> ["t:" <> name, ..seen]
      _ -> seen
    }
  })
}

// A hook that records `tag` followed by the node's constructor.
fn constructor_as(tag: String) -> fn(List(String), node) -> List(String) {
  fn(seen, node) { [tag <> constructor(node), ..seen] }
}

// The name of a node's constructor, such as `PatternTuple`.
fn constructor(node: node) -> String {
  let text = string.inspect(node)
  case string.split_once(text, "(") {
    Ok(#(name, _)) -> name
    Error(Nil) -> text
  }
}

// How many times each tag was seen, sorted by tag.
fn count(seen: List(String)) -> List(#(String, Int)) {
  seen
  |> list.group(fn(tag) { tag })
  |> dict.map_values(fn(_tag, tags) { list.length(tags) })
  |> dict.to_list
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}

// A variable's name, or the kind of any other expression the order tests
// use.
fn describe(expression: glance.Expression) -> String {
  case expression {
    glance.Variable(name:, ..) -> name
    glance.Call(..) -> "call"
    glance.Fn(..) -> "fn"
    _ -> "other"
  }
}
