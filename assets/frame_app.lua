local data = require('data.min')
local battery = require('battery.min')
local sprite = require('sprite.min')
local code = require('code.min')
local text_sprite_block = require('text_sprite_block.min')

-- Phone to Frame flags
TEXT_SPRITE_BLOCK = 0x20
CLEAR_MSG = 0x10

-- register the message parser so it's automatically called when matching data comes in
data.parsers[TEXT_SPRITE_BLOCK] = text_sprite_block.parse_text_sprite_block
data.parsers[CLEAR_MSG] = code.parse_code


-- Main app loop
function app_loop()
	-- clear the display
	frame.display.text(" ", 1, 1)
	frame.display.show()
    local last_batt_update = 0
    local last_text_show = 0
    local showing_content = false

    while true do
        rc, err = pcall(
            function()
                -- process any raw items, if ready (parse into image or text, then clear raw)
                local items_ready = data.process_raw_items()

                if (data.app_data[TEXT_SPRITE_BLOCK] ~= nil) then
                    -- show the text sprite block
                    showing_content = true
                    local tsb = data.app_data[TEXT_SPRITE_BLOCK]
                    local all_sprites = false

                    for index, spr in ipairs(tsb.sprites) do
                        frame.display.bitmap(1, tsb.offsets[index].y + 1, spr.width, 2^spr.bpp, 0, spr.pixel_data)

                        -- all sprites have been drawn
                        if index == tsb.lines then
                            all_sprites = true
                        end
                    end
                    frame.display.show()

                    -- once we've received all the sprites and drawn them
                    -- clear the sprites right away to try to clear the memory
                    if all_sprites then
                        print('shown all sprites')
                        for k, v in pairs(tsb.sprites) do tsb.sprites[k] = nil end
                        data.app_data[TEXT_SPRITE_BLOCK] = nil
                        collectgarbage('collect')

                        last_text_show = frame.time.utc()
                    end
                end

                if (data.app_data[CLEAR_MSG] ~= nil) then
                    -- clear the display
                    frame.display.text(" ", 1, 1)
                    frame.display.show()

                    data.app_data[CLEAR_MSG] = nil
                end
            end
        )
        -- Catch the break signal here and clean up the display
        if rc == false then
            -- send the error back on the stdout stream
            print(err)
            frame.display.text(" ", 1, 1)
            frame.display.show()
            frame.sleep(0.04)
            break
        end


        -- periodic battery level updates, 120s
        last_batt_update = battery.send_batt_if_elapsed(last_batt_update, 120)
		frame.sleep(0.1)

		-- clear the display after showing text for 10 seconds
		if (showing_content and (frame.time.utc() - last_text_show) > 10) then
			frame.display.text(" ", 1, 1)
			frame.display.show()
            frame.sleep(0.04)
            showing_content = false
		end
    end
end

-- run the main app loop
app_loop()