defmodule Dammit.Spec do
  @base_fields [nullable: false, and: nil]

  defmacro __using__(opts \\ []) do
    fields = Keyword.get(opts, :fields, [])
    fields = fields ++ @base_fields

    quote do
      defstruct unquote(fields)

      def new(opts \\ []) do
        with {:ok, spec} <- Dammit.Spec.create_spec(__MODULE__, opts),
             :ok <- Dammit.Spec.validate_base_fields(spec),
             :ok <- Dammit.Spec.check_required_fields(__MODULE__, spec),
             {:ok, spec} <- Dammit.Spec.wrap_validate_spec(__MODULE__, spec) do
          spec
        else
          {:error, reason} -> raise Dammit.SpecError.new(reason)
        end
      end
    end
  end

  def wrap_validate_spec(module, spec) do
    case Dammit.ValidateSpec.validate_spec(spec) do
      :ok -> {:ok, spec}
      # this gives the implementation a chance to transform the spec
      {:ok, %^module{} = spec} -> {:ok, spec}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_base_fields(%{nullable: val}) when not is_boolean(val),
    do: {:error, ":nullable must be a boolean, got #{inspect(val)}"}

  def validate_base_fields(%{and: and_fn}) when not is_nil(and_fn) and not is_function(and_fn, 1),
    do: {:error, ":and must be a 1-arity function, got #{inspect(and_fn)}"}

  def validate_base_fields(_spec), do: :ok

  def check_required_fields(module, spec) do
    missing_field =
      spec
      |> Map.from_struct()
      # To define a spec field as required, give it a default value of
      # :required. If the user doesn't specifiy a val when creating the spec,
      # :required will remain.
      |> Enum.find(fn {_field, val} -> val == :required end)

    case missing_field do
      nil -> :ok
      {field, _val} -> {:error, "#{inspect(field)} is required in #{inspect(module)}"}
    end
  end

  def create_spec(module, opts) do
    try do
      {:ok, struct!(module, opts)}
    rescue
      e in KeyError -> {:error, "#{inspect(e.key)} is not a field of #{inspect(module)}"}
    end
  end

  def get_name(module) do
    ["Elixir" | split_module_name] = module |> to_string() |> String.split(".")
    Enum.join(split_module_name, ".")
  end

  # TODO: maybe have an intermediate public function that checks that the spec is a spec
  # However, we want to avoid double checking all the specs in maps
  def validate(nil, %{nullable: true}), do: :ok
  def validate(nil, %{nullable: false}), do: {:error, "cannot be nil"}

  def validate(val, %{and: and_fn} = spec) do
    # first conform according to the module, then test the value agaist the :and function only if successful
    # delete the and so the implementer can't override the and behavior
    with :ok <- Dammit.ValidateVal.validate_val(spec, val) do
      apply_and_fn(and_fn, val)
    end
  end

  def apply_and_fn(fun, val) when is_function(fun) do
    case fun.(val) do
      :ok -> :ok
      true -> :ok
      false -> {:error, "invalid"}
      msg when is_binary(msg) -> {:error, msg}
      {:error, msg} when is_binary(msg) -> {:error, msg}
    end
  end

  def apply_and_fn(_fun, _val), do: :ok

  def recurse(key_in_parent, value, spec) when is_map(spec) do
    case validate(value, spec) do
      :ok ->
        :ok

      {:error, error_msg} when is_binary(error_msg) ->
        {[key_in_parent], error_msg}

      {:error, error_map} when is_map(error_map) ->
        Enum.map(error_map, fn {path, error_msg} when is_list(path) and is_binary(error_msg) ->
          {[key_in_parent | path], error_msg}
        end)
    end
  end

  def is_spec?(val) do
    not (val |> Dammit.ValidateSpec.impl_for() |> is_nil()) and
      not (val |> Dammit.ValidateVal.impl_for() |> is_nil())
  end
end

defprotocol Dammit.ValidateSpec do
  def validate_spec(spec)
end

defprotocol Dammit.ValidateVal do
  def validate_val(spec, value)
end

defimpl Dammit.ValidateSpec, for: Any do
  def validate_spec(_spec), do: :ok
end

defimpl Dammit.ValidateVal, for: Any do
  def validate_val(_spec, _val), do: :ok
end

defmodule Dammit.Spec.String do
  use Dammit.Spec, fields: [:regex, :one_of, :one_of_ci]
end

defimpl Dammit.ValidateSpec, for: Dammit.Spec.String do
  @non_empty_list_msg "must be a non-empty list of strings"

  def validate_spec(%{regex: regex, one_of: one_of})
      when not is_nil(regex) and not is_nil(one_of),
      do: {:error, "cannot use both :regex and :one_of"}

  def validate_spec(%{regex: regex, one_of_ci: one_of_ci})
      when not is_nil(regex) and not is_nil(one_of_ci),
      do: {:error, "cannot use both :regex and :one_of_ci"}

  def validate_spec(%{one_of: one_of, one_of_ci: one_of_ci})
      when not is_nil(one_of) and not is_nil(one_of_ci),
      do: {:error, "cannot use both :one_of and :one_of_ci"}

  def validate_spec(%{one_of: one_of}) when not (is_list(one_of) or is_nil(one_of)),
    do: {:error, ":one_of #{@non_empty_list_msg}"}

  def validate_spec(%{one_of_ci: one_of_ci}) when not (is_list(one_of_ci) or is_nil(one_of_ci)),
    do: {:error, ":one_of_ci #{@non_empty_list_msg}"}

  def validate_spec(%{one_of: []}), do: {:error, ":one_of #{@non_empty_list_msg}"}

  def validate_spec(%{one_of_ci: []}), do: {:error, ":one_of_ci #{@non_empty_list_msg}"}

  ## Now at most non-null field is will be present

  def validate_spec(%{one_of: one_of}) when is_list(one_of) do
    if Enum.all?(one_of, &is_binary/1) do
      :ok
    else
      {:error, ":one_of #{@non_empty_list_msg}"}
    end
  end

  def validate_spec(%{one_of_ci: one_of_ci} = spec) when is_list(one_of_ci) do
    if Enum.all?(one_of_ci, &is_binary/1) do
      downcased = Enum.map(one_of_ci, &String.downcase/1)
      {:ok, Map.put(spec, :one_of_ci, downcased)}
    else
      {:error, ":one_of_ci #{@non_empty_list_msg}"}
    end
  end

  def validate_spec(%{regex: regex}) when not is_nil(regex) do
    case regex do
      %Regex{} -> :ok
      _ -> {:error, ":regex must be a Regex"}
    end
  end

  def validate_spec(_), do: :ok
end

defimpl Dammit.ValidateVal, for: Dammit.Spec.String do
  def validate_val(_spec, val) when not is_binary(val), do: {:error, "must be a string"}

  def validate_val(%{regex: regex}, val) when not is_nil(regex) do
    if Regex.match?(regex, val) do
      :ok
    else
      {:error, "must match regex: #{Regex.source(regex)}"}
    end
  end

  def validate_val(%{one_of: one_of}, val) when is_list(one_of) do
    if val in one_of do
      :ok
    else
      {:error, "must be a case-sensative match for one of: #{Enum.join(one_of, ", ")}"}
    end
  end

  def validate_val(%{one_of_ci: already_downcased}, val) when is_list(already_downcased) do
    if String.downcase(val) in already_downcased do
      :ok
    else
      {:error,
       "must be a case-insensative match for one of: #{Enum.join(already_downcased, ", ")}"}
    end
  end

  def validate_val(_spec, _val), do: :ok
end

defmodule Dammit.Spec.Boolean do
  @derive [Dammit.ValidateSpec]
  use Dammit.Spec
end

defimpl Dammit.ValidateVal, for: Dammit.Spec.Boolean do
  def validate_val(_spec, val) when is_boolean(val), do: :ok
  def validate_val(_spec, _val), do: {:error, "must be a boolean"}
end

defmodule Dammit.Spec.Decimal do
  @decimal_regex ~r/^\s*-?\d*\.?\d+\s*$/

  use Dammit.Spec,
    fields: [
      :gt,
      :lt,
      :gte,
      :lte,
      :max_decimal_places,
      :get_error_message,
      # TODO: do a check like for :required that tells them they can't supply this
      error_message: :internal
    ]

  def is_decimal_string(it) when is_binary(it) do
    Regex.match?(@decimal_regex, it)
  end

  def is_decimal_string(_), do: false

  def decimal_regex, do: @decimal_regex
end

defimpl Dammit.ValidateSpec, for: Dammit.Spec.Decimal do
  @bad_bounds_spec_error_msg "must be a Decimal, a decimal-formatted string, or an integer"

  def validate_spec(%{max_decimal_places: max_decimal_places})
      when not is_nil(max_decimal_places) and
             (not is_integer(max_decimal_places) or max_decimal_places < 1) do
    {:error, ":max_decimal_places must be a positive integer"}
  end

  def validate_spec(params) do
    with {:ok, params} <- parse_decimal_or_nil(params, :lt),
         {:ok, params} <- parse_decimal_or_nil(params, :gt),
         {:ok, params} <- parse_decimal_or_nil(params, :lte),
         {:ok, params} <- parse_decimal_or_nil(params, :gte),
         :ok <- at_most_one(params, :lt, :lte),
         :ok <- at_most_one(params, :gt, :gte),
         :ok <- ensure_logical_bounds(params),
         {:ok, params} <- add_error_message(params) do
      {:ok, params}
    end
  end

  defp at_most_one(params, bound1, bound2) do
    b1 = Map.get(params, bound1)
    b2 = Map.get(params, bound2)

    if is_nil(b1) || is_nil(b2) do
      :ok
    else
      {:error, "cannot use both #{inspect(bound1)} and #{inspect(bound2)}"}
    end
  end

  defp ensure_logical_bounds(params) do
    # at this point, at_most_one/3 hessage ensured there is at most one lower orupper:  bound
    lower_bound_tuple =
      case {Map.get(params, :gt), Map.get(params, :gte)} do
        {nil, nil} -> nil
        {gt, nil} -> {:gt, gt}
        {nil, gte} -> {:gte, gte}
      end

    upper_bound_tuple =
      case {Map.get(params, :lt), Map.get(params, :lte)} do
        {nil, nil} -> nil
        {lt, nil} -> {:lt, lt}
        {nil, lte} -> {:lte, lte}
      end

    case {lower_bound_tuple, upper_bound_tuple} do
      {l, u} when is_nil(l) or is_nil(u) ->
        :ok

      {{lower_k, lower_v}, {upper_k, upper_v}} ->
        if Decimal.lt?(lower_v, upper_v) do
          :ok
        else
          {:error, "#{inspect(lower_k)} must be less than #{inspect(upper_k)}"}
        end
    end
  end

  def get_error_message(%Dammit.Spec.Decimal{} = params) do
    # add the details in the opposite order that they'll be displayed so we can append to the front of the list and reverse at the end.
    details =
      case params.max_decimal_places do
        nil -> []
        num -> ["with up to #{num} decimal places"]
      end

    details =
      Enum.reduce(
        [
          gt: "greater than",
          gte: "greater than or equal to",
          lt: "less than",
          lte: "less than or equal to"
        ],
        details,
        fn {bound, desc}, details ->
          case Map.get(params, bound) do
            nil -> details
            decimal -> ["#{desc} #{Decimal.to_string(decimal, :normal)}" | details]
          end
        end
      )

    msg_start = "must be a decimal-formatted string"

    case Enum.reverse(details) do
      [] -> msg_start
      [d1] -> msg_start <> " " <> d1
      [d1, d2] -> msg_start <> " " <> d1 <> " and " <> d2
      [d1, d2, d3] -> msg_start <> " " <> d1 <> ", " <> d2 <> ", and " <> d3
    end
  end

  def add_error_message(params) do
    error_message =
      if is_function(params.get_error_message, 1) do
        params.get_error_message.(params)
      else
        get_error_message(params)
      end

    {:ok, Map.put(params, :error_message, error_message)}
  end

  defp parse_decimal_or_nil(params, bound) do
    val = params |> Map.from_struct() |> Map.get(bound)

    case val do
      nil ->
        {:ok, params}

      %Decimal{} ->
        {:ok, params}

      int when is_integer(int) ->
        {:ok, Map.put(params, bound, Decimal.new(val))}

      str when is_binary(str) ->
        if Regex.match?(Dammit.Spec.Decimal.decimal_regex(), str) do
          {:ok, Map.put(params, bound, Decimal.new(val))}
        else
          {:error, "#{inspect(bound)} #{@bad_bounds_spec_error_msg}"}
        end

      _ ->
        {:error, "#{inspect(bound)} #{@bad_bounds_spec_error_msg}"}
    end
  end
end

defimpl Dammit.ValidateVal, for: Dammit.Spec.Decimal do
  def validate_val(
        %{
          lt: lt,
          gt: gt,
          lte: lte,
          gte: gte,
          max_decimal_places: max_decimal_places,
          error_message: error_message
        },
        val
      ) do
    with true <-
           Dammit.Spec.Decimal.is_decimal_string(val),
         true <- lt == nil or Decimal.lt?(val, lt),
         true <- lte == nil or not Decimal.gt?(val, lte),
         true <- gt == nil or Decimal.gt?(val, gt),
         true <- gte == nil or not Decimal.lt?(val, gte),
         true <- valid_decimal_places(val, max_decimal_places) do
      :ok
    else
      _ -> {:error, error_message}
    end
  end

  defp valid_decimal_places(val, max_decimal_places) do
    case String.split(val, ".") do
      [_] -> true
      [_, after_dot] -> String.length(after_dot) <= max_decimal_places
    end
  end
end


defmodule Dammit.Spec.Map do
  use Dammit.Spec,
    fields: [required: %{}, optional: %{}, exclusive: false]
end

defimpl Dammit.ValidateSpec, for: Dammit.Spec.Map do
  @bad_fields_msg "must be a map or keyword list of field names to specs"

  def validate_spec(%{exclusive: exclusive}) when not is_boolean(exclusive),
    do: {:error, ":exclusive must be a boolean"}

  def validate_spec(%{required: required, optional: optional} = spec) do
    with {:ok, transformed_required} <- get_as_map_of_specs(required, :required),
         {:ok, transformed_optional} <- get_as_map_of_specs(optional, :optional) do
      transformed_spec =
        Map.merge(spec, %{required: transformed_required, optional: transformed_optional})

      {:ok, transformed_spec}
    end
  end

  def get_as_map_of_specs(map, field) when is_map(map) do
    if is_map_of_specs?(map),
      do: {:ok, map},
      else: {:error, "#{inspect(field)} #{@bad_fields_msg}"}
  end

  def get_as_map_of_specs(maybe_keyed_specs, field) do
    if Keyword.keyword?(maybe_keyed_specs) do
      maybe_keyed_specs
      |> Map.new()
      |> get_as_map_of_specs(field)
    else
      {:error, "#{inspect(field)} #{@bad_fields_msg}"}
    end
  end

  def is_map_of_specs?(map) do
    Enum.all?(map, fn {name, val} ->
      good_name = is_atom(name) or is_binary(name)
      good_val = Dammit.Spec.is_spec?(val)
      good_name and good_val
    end)
  end
end

defimpl Dammit.ValidateVal, for: Dammit.Spec.Map do
  def validate_val(%{} = _spec, val) when not is_map(val), do: {:error, "must be a map"}

  def validate_val(%{required: required, optional: optional, exclusive: exclusive} = _spec, map) do
    disallowed_field_errors =
      if exclusive do
        allowed_fields = Map.keys(required) ++ Map.keys(optional)

        map
        |> Map.drop(allowed_fields)
        |> Map.keys()
        |> Enum.map(fn field -> {[field], "is not allowed"} end)
      else
        []
      end

    required_field_names = required |> Map.keys() |> MapSet.new()
    field_names = map |> Map.keys() |> MapSet.new()

    missing_required_field_names = MapSet.difference(required_field_names, field_names)

    missing_required_field_errors = Enum.map(missing_required_field_names, &{[&1], "is required"})

    required_field_errors =
      required
      |> Enum.map(fn {field_name, spec} ->
        if Map.has_key?(map, field_name) do
          Dammit.Spec.recurse(field_name, map[field_name], spec)
        else
          :ok
        end
      end)
      |> Enum.filter(&(&1 != :ok))
      |> List.flatten()

    optional_field_errors =
      optional
      |> Enum.map(fn {field_name, spec} ->
        if Map.has_key?(map, field_name) do
          Dammit.Spec.recurse(field_name, map[field_name], spec)
        else
          :ok
        end
      end)
      |> Enum.filter(&(&1 != :ok))
      |> List.flatten()

    all_errors =
      List.flatten([
        disallowed_field_errors,
        missing_required_field_errors,
        required_field_errors,
        optional_field_errors
      ])

    case all_errors do
      [] -> :ok
      errors when is_list(errors) -> {:error, Map.new(errors)}
    end
  end
end

defmodule Dammit.Spec.List do
  use Dammit.Spec,
    fields: [:min_len, :max_len, of: :required]
end

defimpl Dammit.ValidateSpec, for: Dammit.Spec.List do
  def validate_spec(%{min_len: min_len})
      when not is_nil(min_len) and not (is_integer(min_len) and min_len >= 0),
      do: {:error, ":min_len must be a non-negative integer"}

  def validate_spec(%{max_len: max_len})
      when not is_nil(max_len) and not (is_integer(max_len) and max_len >= 0),
      do: {:error, ":max_len must be a non-negative integer"}

  def validate_spec(%{min_len: min_len, max_len: max_len})
      when is_integer(min_len) and is_integer(max_len) and min_len > max_len,
      do: {:error, ":min_len cannot be greater than :max_len"}

  def validate_spec(%{of: of}) do
    if Dammit.Spec.is_spec?(of),
      do: :ok,
      else: {:error, ":of must be a spec"}
  end

  def validate_spec(_spec), do: :ok
end

defimpl Dammit.ValidateVal, for: Dammit.Spec.List do
  def validate_val(%{} = _spec, val) when not is_list(val), do: {:error, "must be a list"}

  def validate_val(%{of: item_spec, min_len: min_len, max_len: max_len} = _spec, list) do
    with :ok <- validate_min_len(list, min_len),
         :ok <- validate_max_len(list, max_len) do
      item_errors =
        list
        |> Enum.with_index()
        |> Enum.map(fn {item, index} ->
          Dammit.Spec.recurse(index, item, item_spec)
        end)
        |> Enum.filter(&(&1 != :ok))
        |> Map.new()

      if item_errors == %{} do
        :ok
      else
        {:error, item_errors}
      end
    end
  end

  defp validate_min_len(_list, nil), do: :ok

  defp validate_min_len(list, min) do
    if length(list) < min do
      {:error, "length must be at least #{min}"}
    else
      :ok
    end
  end

  defp validate_max_len(_list, nil), do: :ok

  defp validate_max_len(list, max) do
    if length(list) > max do
      {:error, "length cannot exceed #{max}"}
    else
      :ok
    end
  end
end
