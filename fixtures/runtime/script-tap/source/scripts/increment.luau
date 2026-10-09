return function(context)
    return {
        performAction = function(self, event)
            local count = context:viewModel():getViewModel("state").value:getNumber("count")
            count.value = count.value + 1
        end,
    }
end
