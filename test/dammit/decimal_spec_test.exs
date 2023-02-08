defmodule Dammit.DecimalSpecTest do
  alias Dammit.SpecError
  alias Dammit.Spec
  alias Dammit.DecimalSpec

  use ExUnit.Case

  describe "DecimalSpec.new/1" do
    test "creates a decimal spec" do
      default_error_message = "must be a decimal-formatted string"
      assert DecimalSpec.new() == %DecimalSpec{error_message: default_error_message}

      assert DecimalSpec.new(gt: 5, lt: "10.01") == %DecimalSpec{
               gt: Decimal.new("5"),
               lt: Decimal.new("10.01"),
               error_message: default_error_message <> " greater than 5 and less than 10.01"
             }

      assert DecimalSpec.new(gte: 5, lte: "10.01") == %DecimalSpec{
               gte: Decimal.new("5"),
               lte: Decimal.new("10.01"),
               error_message:
                 default_error_message <>
                   " greater than or equal to 5 and less than or equal to 10.01"
             }

      # overwrite the default get_error_message function 
      get_error_message = fn spec -> "gotta be at least #{spec.gte} and at most #{spec.lte}" end

      assert DecimalSpec.new(gte: 1, lte: 5, get_error_message: get_error_message) ==
               %DecimalSpec{
                 gte: Decimal.new("1"),
                 lte: Decimal.new("5"),
                 error_message: "gotta be at least 1 and at most 5",
                 get_error_message: get_error_message
               }

      Enum.each([:lt, :lte, :gt, :gte], fn comp ->
        assert_raise SpecError,
                     "#{inspect(comp)} must be a Decimal, a decimal-formatted string, or an integer",
                     fn ->
                       DecimalSpec.new([{comp, "f00py"}])
                     end
      end)

      assert_raise SpecError, "cannot use both :gt and :gte", fn ->
        DecimalSpec.new(gt: 5, gte: 3)
      end

      assert_raise SpecError, "cannot use both :lt and :lte", fn ->
        DecimalSpec.new(lt: 5, lte: 3)
      end

      for lower <- [:gt, :gte], upper <- [:lt, :lte] do
        assert_raise SpecError, "#{inspect(lower)} must be less than #{inspect(upper)}", fn ->
          DecimalSpec.new([{lower, 5}, {upper, 4}])
        end

        assert_raise SpecError, "#{inspect(lower)} must be less than #{inspect(upper)}", fn ->
          DecimalSpec.new([{lower, 5}, {upper, 5}])
        end
      end

      assert_raise SpecError, ":max_decimal_places must be a positive integer", fn ->
        DecimalSpec.new(max_decimal_places: "3")
      end

      assert_raise SpecError, ":max_decimal_places must be a positive integer", fn ->
        DecimalSpec.new(max_decimal_places: -3)
      end
    end

    test "validates a decimal, basic test" do
      spec = assert DecimalSpec.new()

      assert :ok = Spec.validate("4", spec)
      assert :ok = Spec.validate(" 4 ", spec)
      assert :ok = Spec.validate("-14", spec)
      assert :ok = Spec.validate(" -14 ", spec)
      assert :ok = Spec.validate("4.00", spec)
      assert :ok = Spec.validate("-4.00", spec)
      assert :ok = Spec.validate("-47.00", spec)
      assert :ok = Spec.validate(".47", spec)
      assert :ok = Spec.validate(" .47 ", spec)
      assert :ok = Spec.validate("-.47", spec)
      assert :ok = Spec.validate(" -.47 ", spec)
      assert {:error, _} = Spec.validate("foo", spec)
      assert {:error, _} = Spec.validate("1.1.", spec)
      assert {:error, _} = Spec.validate(".1.1", spec)
      assert {:error, _} = Spec.validate(" ", spec)
      assert {:error, _} = Spec.validate(".", spec)
      assert {:error, _} = Spec.validate("..", spec)
      assert {:error, _} = Spec.validate(1, spec)
      assert {:error, _} = Spec.validate(Decimal.new(4), spec)
      assert {:error, _} = Spec.validate(nil, spec)
    end

    test "a decimal spec with exclusive bounds" do
      spec = assert DecimalSpec.new(gt: 1, lt: 3)
      assert {:error, _} = Spec.validate("1", spec)
      assert :ok = Spec.validate("2", spec)
      assert {:error, _} = Spec.validate("3", spec)
    end

    test "a decimal spec with inclusive bounds" do
      spec = assert DecimalSpec.new(gte: 1, lte: 3)
      assert {:error, _} = Spec.validate("0.999", spec)
      assert :ok = Spec.validate("1", spec)
      assert :ok = Spec.validate("2", spec)
      assert :ok = Spec.validate("3", spec)
      assert {:error, _} = Spec.validate("3.001", spec)
    end

    test "a decimal spec with max_decimal_places" do
      spec = assert DecimalSpec.new(max_decimal_places: 2)
      assert :ok = Spec.validate("1.0", spec)
      assert :ok = Spec.validate("1.00", spec)
      assert {:error, _} = Spec.validate("1.000", spec)
    end
  end
end
