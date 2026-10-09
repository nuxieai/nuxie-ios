local nuxie = require("nuxie")
return function(context)
    return { performAction = function(self, event)
        self.taps = (self.taps or 0) + 1
        local ok, rule
        if self.taps == 1 then
            ok, rule = nuxie.responses.set("signup.picks", {"b", "c"})
        elseif self.taps == 2 then
            ok, rule = nuxie.responses.set("signup.picks", {"b"})
        else
            ok, rule = nuxie.responses.set("signup.picks", nil)
        end
        nuxie.trigger("checked", {ok = ok, rule = rule})
    end }
end
