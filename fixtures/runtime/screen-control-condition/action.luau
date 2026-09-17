local Nuxie = require("nuxie")
return function(context)
  return { actions = { submit = function(invocation)
    Nuxie.response.set("selection", "pro")
    Nuxie.emit("script_control_activated", { source = "compiled" })
  end } }
end