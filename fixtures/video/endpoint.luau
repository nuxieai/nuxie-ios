-- Source-endpoint qualification: the final 10 fps image is 100 ms before duration.
return function()
    return {
        init = function(self, context)
            self.context = context
            self.paint = Paint.with({ color = 0xff8b80ff })
            self.path = Path.new()
            return true
        end,
        advance = function(self, seconds)
            self.video = self.video or self.context:video("Video")
            local duration = self.video and self.video:duration()
            if not duration or duration <= 0 then return true end
            if not self.request then self.request = self.video:scrub(1, 0, duration) end
            local status = self.video:requestStatus()
            self.settled = status and status.id == self.request and status.state == "settled" and duration >= 1.99
            return not self.settled
        end,
        draw = function(self, renderer)
            self.path:reset()
            self.path:moveTo(Vector(20, 586))
            self.path:lineTo(Vector(300, 586))
            self.path:lineTo(Vector(300, 590))
            self.path:lineTo(Vector(20, 590))
            self.path:close()
            self.paint.color = self.settled and 0xff58be92 or 0xff8b80ff
            renderer:drawPath(self.path, self.paint)
        end,
    }
end
