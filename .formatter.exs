# The DSL of the framework is written without parentheses (`field :name, :string`). An
# application that lists `:vicander` in `import_deps` gets the same.
locals_without_parens = [
  field: 2,
  field: 3,
  identity: 2,
  identity: 3,
  invariant: 1,
  invariant: 2,
  validate: 2,
  validate: 3,
  defop: 2,
  defop: 3,
  description: 1,
  find_by: 1,
  on: 2
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
