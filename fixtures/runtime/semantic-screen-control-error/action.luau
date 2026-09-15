local Nuxie = require("nuxie")
return function(context)
  return { actions = { submit = function(invocation)
    Nuxie.response.set("selection", "pro")
    error("script_failure_probe")
  end } }
end