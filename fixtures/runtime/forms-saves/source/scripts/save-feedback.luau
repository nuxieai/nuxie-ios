local nuxie = require("nuxie")
return function(context)
    return {
        performAction = function(self, event)
            nuxie.responses.save("feedback")
        end,
    }
end
