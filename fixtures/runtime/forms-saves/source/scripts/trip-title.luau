return function(): Converter<{}, DataValueNumber, DataValueString>
  return {
    convert = function(self, input)
      local output = DataValue.string()
      output.value = "Italy in " .. tostring(math.floor(input.value)) .. (input.value == 1 and " day." or " days.")
      return output
    end,
  }
end
