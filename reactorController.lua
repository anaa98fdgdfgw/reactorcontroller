local version = "0.62"
local tag = "reactorConfig"

--[[
Reactor Controller - Adaptive UI Version
Based on DrunkenKas's original work with full adaptive interface system
Enhanced for VNC compatibility and all screen sizes
]]

-- Système de compatibilité touchpoint/fallback
local touchpointAvailable = pcall(function() dofile("/usr/apis/touchpoint.lua") end)
if not touchpointAvailable then
    -- Fallback touchpoint system pour VNC/terminal
    touchpoint = {
        new = function(side)
            return {
                add = function(self, name, callback, x1, y1, x2, y2, color1, color2)
                    self.buttonList = self.buttonList or {}
                    self.buttonList[name] = {
                        func = callback,
                        x1 = x1, y1 = y1, x2 = x2, y2 = y2,
                        color1 = color1, color2 = color2,
                        active = false
                    }
                end,
                toggleButton = function(self, name, state)
                    if self.buttonList and self.buttonList[name] then
                        self.buttonList[name].active = state or not self.buttonList[name].active
                    end
                end,
                draw = function(self)
                    if not self.buttonList then return end
                    for name, btn in pairs(self.buttonList) do
                        self:drawButton(name, btn)
                    end
                end,
                drawButton = function(self, name, btn)
                    local output = monSide and mon or term
                    if not output then return end
                    
                    local color = btn.active and btn.color2 or btn.color1
                    output.setBackgroundColor(color)
                    
                    for y = btn.y1, btn.y2 do
                        if y >= 1 and y <= (monSide and sizey or select(2, term.getSize())) then
                            output.setCursorPos(btn.x1, y)
                            output.write(string.rep(" ", btn.x2 - btn.x1 + 1))
                        end
                    end
                    
                    local text = name
                    local textX = btn.x1 + math.floor((btn.x2 - btn.x1 + 1 - #text) / 2)
                    local textY = btn.y1 + math.floor((btn.y2 - btn.y1) / 2)
                    
                    if textY >= 1 and textY <= (monSide and sizey or select(2, term.getSize())) then
                        output.setCursorPos(textX, textY)
                        output.setTextColor(btn.active and colors.black or colors.white)
                        output.write(text)
                    end
                    
                    output.setBackgroundColor(colors.black)
                    output.setTextColor(colors.white)
                end,
                handleEvents = function(self)
                    local event = { os.pullEvent() }
                    
                    if event[1] == "mouse_click" and self.buttonList then
                        local x, y = event[3], event[4]
                        for name, btn in pairs(self.buttonList) do
                            if x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2 then
                                return {"button_click", name}
                            end
                        end
                    end
                    
                    return event
                end
            }
        end
    }
end

local reactorVersion, reactor
local mon, monSide
local sizex, sizey, dim, oo, offy
local btnOn, btnOff, invalidDim
local minb, maxb
local rod, rfLost
local storedLastTick, storedThisTick, lastRFT = 0,0,0
local fuelTemp, caseTemp, fuelUsage, waste, capacity = 0,0,0,0,1
local t
local displayingGraphMenu = false

local secondsToAverage = 2

local averageStoredThisTick = 0
local averageLastRFT = 0
local averageRod = 0
local averageFuelUsage = 0
local averageWaste = 0
local averageFuelTemp = 0
local averageCaseTemp = 0
local averageRfLost = 0

-- table of which graphs to draw
local graphsToDraw = {}

-- table of all the graphs
local graphs =
{
    "Energy Buffer",
    "Control Level",
    "Temperatures",
}

-- marks the offsets for each graph position - made adaptive
local XOffs =
{
    { 4, true},
    {27, true},
    {50, true},
    {73, true},
    {96, true},
}

-- Fonctions de dessin adaptatives
local function getOutput()
    return monSide and mon or term
end

local function getScreenSize()
    if monSide and mon then
        return mon.getSize()
    else
        return term.getSize()
    end
end

local function detectScreenType()
    local w, h = getScreenSize()
    
    if w <= 26 and h <= 20 then
        return "pocket"
    elseif w <= 50 or h <= 30 then
        return "compact"
    elseif w <= 80 or h <= 40 then
        return "vnc"
    else
        return "standard"
    end
end

-- Draw a box with no fill - adaptative
local function drawBox(size, xoff, yoff, color)
    local output = getOutput()
    if not output then return end
    
    local w, h = getScreenSize()
    if xoff < 0 or yoff < 0 or xoff >= w or yoff >= h then return end
    
    local x,y = output.getCursorPos()
    output.setBackgroundColor(color)
    local horizLine = string.rep(" ", math.min(size[1], w - xoff))
    
    if yoff + 1 >= 1 and yoff + 1 <= h then
        output.setCursorPos(xoff + 1, yoff + 1)
        output.write(horizLine)
    end
    
    if yoff + size[2] >= 1 and yoff + size[2] <= h then
        output.setCursorPos(xoff + 1, yoff + size[2])
        output.write(horizLine)
    end

    -- Draw vertical lines
    for i=0, size[2] - 1 do
        local lineY = yoff + i + 1
        if lineY >= 1 and lineY <= h then
            if xoff + 1 >= 1 and xoff + 1 <= w then
                output.setCursorPos(xoff + 1, lineY)
                output.write(" ")
            end
            if xoff + size[1] >= 1 and xoff + size[1] <= w then
                output.setCursorPos(xoff + size[1], lineY)
                output.write(" ")
            end
        end
    end
    output.setCursorPos(x,y)
    output.setBackgroundColor(colors.black)
end

--Draw a filled box - adaptative
local function drawFilledBox(size, xoff, yoff, colorOut, colorIn)
    local output = getOutput()
    if not output then return end
    
    local w, h = getScreenSize()
    if xoff < 0 or yoff < 0 or xoff >= w or yoff >= h then return end
    
    local horizLine = string.rep(" ", math.max(0, math.min(size[1] - 2, w - xoff - 1)))
    drawBox(size, xoff, yoff, colorOut)
    local x,y = output.getCursorPos()
    output.setBackgroundColor(colorIn)
    for i=2, size[2] - 1 do
        local lineY = yoff + i
        if lineY >= 1 and lineY <= h and xoff + 2 >= 1 and xoff + 2 <= w then
            output.setCursorPos(xoff + 2, lineY)
            output.write(horizLine)
        end
    end
    output.setBackgroundColor(colors.black)
    output.setCursorPos(x,y)
end

--Draws text on the screen - adaptative
local function drawText(text, x1, y1, backColor, textColor)
    local output = getOutput()
    if not output then return end
    
    local w, h = getScreenSize()
    if x1 < 1 or y1 < 1 or x1 > w or y1 > h then return end
    
    local x, y = output.getCursorPos()
    output.setCursorPos(x1, y1)
    output.setBackgroundColor(backColor)
    output.setTextColor(textColor)
    local maxLen = math.max(0, w - x1 + 1)
    output.write(text:sub(1, maxLen))
    output.setTextColor(colors.white)
    output.setBackgroundColor(colors.black)
    output.setCursorPos(x,y)
end

--Helper method for adding buttons - adaptative
local function addButt(name, callBack, size, xoff, yoff, color1, color2)
    if not t then return end
    
    local w, h = getScreenSize()
    -- Adapter la position et taille si nécessaire
    local adjustedX = math.max(1, math.min(xoff + 1, w))
    local adjustedY = math.max(1, math.min(yoff + 1, h))
    local adjustedX2 = math.max(adjustedX, math.min(size[1] + xoff, w))
    local adjustedY2 = math.max(adjustedY, math.min(size[2] + yoff, h))
    
    t:add(name, callBack, adjustedX, adjustedY, adjustedX2, adjustedY2, color1, color2)
end

local function minAdd10()
    minb = math.min(maxb - 10, minb + 10)
end
local function minSub10()
    minb = math.max(0, minb - 10)
end
local function minAdd1()
    minb = math.min(maxb - 1, minb + 1)
end
local function minSub1()
    minb = math.max(0, minb - 1)
end
local function maxAdd10()
    maxb = math.min(100, maxb + 10)
end
local function maxSub10()
    maxb = math.max(minb + 10, maxb - 10)
end
local function maxAdd1()
    maxb = math.min(100, maxb + 1)
end
local function maxSub1()
    maxb = math.max(minb + 1, maxb - 1)
end

local function turnOff()
    if (btnOn) then
        t:toggleButton("Off")
        t:toggleButton("On")
        btnOff = true
        btnOn = false
        reactor.setActive(false)
    end
end

local function turnOn()
    if (btnOff) then
        t:toggleButton("Off")
        t:toggleButton("On")
        btnOff = false
        btnOn = true
        reactor.setActive(true)
    end
end

--adds buttons - adaptative selon la taille d'écran
local function addButtons()
    local screenType = detectScreenType()
    local w, h = getScreenSize()
    
    if screenType == "pocket" then
        -- Interface pocket computer ultra-compacte
        addButt("On", turnOn, {6, 2}, 1, h - 3, colors.red, colors.lime)
        addButt("Off", turnOff, {6, 2}, 8, h - 3, colors.red, colors.lime)
        addButt("Exit", function() error("Terminated") end, {6, 2}, 15, h - 3, colors.gray, colors.red)
        
    elseif screenType == "compact" then
        -- Interface compacte
        local buttonY = math.max(1, h - 8)
        addButt("On", turnOn, {6, 2}, 2, buttonY, colors.red, colors.lime)
        addButt("Off", turnOff, {6, 2}, 10, buttonY, colors.red, colors.lime)
        
        if h > 20 then
            addButt("Min-10", minSub10, {5, 2}, 2, buttonY + 3, colors.purple, colors.pink)
            addButt("Min+10", minAdd10, {5, 2}, 8, buttonY + 3, colors.purple, colors.pink)
            addButt("Max-10", maxSub10, {5, 2}, 14, buttonY + 3, colors.magenta, colors.pink)
            addButt("Max+10", maxAdd10, {5, 2}, 20, buttonY + 3, colors.magenta, colors.pink)
        end
        
    elseif screenType == "vnc" then
        -- Interface VNC adaptée
        if (sizey == 24) then
            oo = 1
        end
        addButt("On", turnOn, {8, 3}, dim + 7, 3 + oo, colors.red, colors.lime)
        addButt("Off", turnOff, {8, 3}, dim + 19, 3 + oo, colors.red, colors.lime)
        
        if (sizey > 24) then
            addButt("Min-10", minSub10, {6, 2}, dim + 5, 14 + oo, colors.purple, colors.pink)
            addButt("Min-1", minSub1, {4, 2}, dim + 12, 14 + oo, colors.purple, colors.pink)
            addButt("Min+1", minAdd1, {4, 2}, dim + 17, 14 + oo, colors.purple, colors.pink)
            addButt("Min+10", minAdd10, {6, 2}, dim + 22, 14 + oo, colors.purple, colors.pink)
            
            addButt("Max-10", maxSub10, {6, 2}, dim + 5, 17 + oo, colors.magenta, colors.pink)
            addButt("Max-1", maxSub1, {4, 2}, dim + 12, 17 + oo, colors.magenta, colors.pink)
            addButt("Max+1", maxAdd1, {4, 2}, dim + 17, 17 + oo, colors.magenta, colors.pink)
            addButt("Max+10", maxAdd10, {6, 2}, dim + 22, 17 + oo, colors.magenta, colors.pink)
        end
        
    else
        -- Interface standard (code original)
        if (sizey == 24) then
            oo = 1
        end
        addButt("On", turnOn, {8, 3}, dim + 7, 3 + oo, colors.red, colors.lime)
        addButt("Off", turnOff, {8, 3}, dim + 19, 3 + oo, colors.red, colors.lime)
        
        if (sizey > 24) then
            addButt("+ 10", minAdd10, {8, 3}, dim + 7, 14 + oo, colors.purple, colors.pink)
            addButt(" + 10 ", maxAdd10, {8, 3}, dim + 19, 14 + oo, colors.magenta, colors.pink)
            addButt("- 10", minSub10, {8, 3}, dim + 7, 18 + oo, colors.purple, colors.pink)
            addButt(" - 10 ", maxSub10, {8, 3}, dim + 19, 18 + oo, colors.magenta, colors.pink)
        end
    end
    
    if (btnOn) then
        t:toggleButton("On", true)
    else
        t:toggleButton("Off", true)
    end
end

--Resets the monitor/terminal - adaptative
local function resetMon()
    local output = getOutput()
    if not output then return end
    
    output.setBackgroundColor(colors.black)
    output.clear()
    if monSide and mon then
        mon.setTextScale(0.5)
    end
    output.setCursorPos(1,1)
end

local function getPercPower()
    return averageStoredThisTick / capacity * 100
end

local function rnd(num, dig)
    return math.floor(10 ^ dig * num) / (10 ^ dig)
end

local function getEfficiency()
    return averageLastRFT / averageFuelUsage
end

local function format(num)
    if (num >= 1000000000) then
        return string.format("%7.3f G", num / 1000000000)
    elseif (num >= 1000000) then
        return string.format("%7.3f M", num / 1000000)
    elseif (num >= 1000) then
        return string.format("%7.3f K", num / 1000)
    elseif (num >= 1) then
        return string.format("%7.3f ", num)
    elseif (num >= .001) then
        return string.format("%7.3f m", num * 1000)
    elseif (num >= .000001) then
        return string.format("%7.3f u", num * 1000000)
    else
        return string.format("%7.3f ", 0)
    end
end

-- Gestion adaptative des positions de graphiques
local function getAvailableXOff()
    for i,v in pairs(XOffs) do
        if (v[2] and v[1] < dim) then
            v[2] = false
            return v[1]
        end
    end
    return -1
end

local function getXOff(num)
    for i,v in pairs(XOffs) do
        if (v[1] == num) then
            return v
        end
    end
    return nil
end

local function enableGraph(name)
    if (graphsToDraw[name] ~= nil) then
        return
    end
    local e = getAvailableXOff()
    if (e ~= -1) then
        graphsToDraw[name] = e
        if (displayingGraphMenu) then
            t:toggleButton(name)
        end
    end
end

local function disableGraph(name)
    if (graphsToDraw[name] == nil) then
        return
    end
    if (displayingGraphMenu) then
        t:toggleButton(name)
    end
    getXOff(graphsToDraw[name])[2] = true
    graphsToDraw[name] = nil
end

local function toggleGraph(name)
    if (graphsToDraw[name] == nil) then
        enableGraph(name)
    else
        disableGraph(name)
    end
end

local function addGraphButtons()
    offy = oo - 14
    for i,v in pairs(graphs) do
        addButt(v, function() toggleGraph(v) end, {20, 3},
                dim + 7, offy + i * 3 - 1,
                colors.red, colors.lime)
        if (graphsToDraw[v] ~= nil) then
            t:toggleButton(v, true)
        end
    end
end

local function drawGraphButtons()
    drawBox({sizex - dim - 3, oo - offy - 1},
            dim + 2, offy, colors.orange)
    drawText(" Graph Controls ",
            dim + 7, offy + 1,
            colors.black, colors.orange)
end

-- Graphiques adaptatifs
local function drawEnergyBuffer(xoff, graphWidth, graphHeight)
    local srf = graphHeight or (sizey - 9)
    local gWidth = graphWidth or 15
    local off = xoff
    local w, h = getScreenSize()
    local right = off + 19 < dim
    local poff = right and off + 15 or off - 6

    -- Adapter la taille selon l'écran
    gWidth = math.min(gWidth, w - off - 1)
    srf = math.min(srf, h - 6)

    drawBox({gWidth, srf + 2}, off - 1, 4, colors.lightBlue)
    local pwr = math.floor(getPercPower() / 100 * srf)
    drawFilledBox({gWidth - 2, srf}, off, 5, colors.red, colors.red)
    
    local rndpw = rnd(getPercPower(), 2)
    local color = (rndpw < maxb and rndpw > minb) and colors.green
            or (rndpw >= maxb and colors.orange or colors.blue)
    
    if (pwr > 0) then
        drawFilledBox({gWidth - 2, pwr + 1}, off, srf + 4 - pwr, color, color)
    end
    
    -- Adapter le texte selon la largeur
    if gWidth >= 15 then
        drawText("Energy Buffer", off + 1, 4, colors.black, colors.orange)
        drawText(string.format(right and "%.2f%%" or "%5.2f%%", rndpw), poff, srf + 5 - pwr,
                colors.black, color)
        drawText(format(averageStoredThisTick).."RF", off + 1, srf + 5 - pwr,
                pwr > 0 and color or colors.red, colors.black)
    elseif gWidth >= 8 then
        drawText("Energy", off + 1, 4, colors.black, colors.orange)
        drawText(string.format("%.0f%%", rndpw), off + 1, srf + 5 - pwr,
                pwr > 0 and color or colors.red, colors.black)
    else
        drawText("E", off + 1, 4, colors.black, colors.orange)
    end
end

local function drawControlLevel(xoff, graphWidth, graphHeight)
    local srf = graphHeight or (sizey - 9)
    local gWidth = graphWidth or 15
    local off = xoff
    local w, h = getScreenSize()
    
    -- Adapter la taille selon l'écran
    gWidth = math.min(gWidth, w - off - 1)
    srf = math.min(srf, h - 6)
    
    drawBox({gWidth, srf + 2}, off - 1, 4, colors.lightBlue)
    drawFilledBox({gWidth - 2, srf}, off, 5, colors.yellow, colors.yellow)
    
    local rodTr = math.floor(averageRod / 100 * srf)
    
    if gWidth >= 15 then
        drawText("Control Level", off + 1, 4, colors.black, colors.orange)
    elseif gWidth >= 8 then
        drawText("Control", off + 1, 4, colors.black, colors.orange)
    else
        drawText("C", off + 1, 4, colors.black, colors.orange)
    end
    
    if (rodTr > 0) then
        local barWidth = math.max(1, gWidth - 6)
        drawFilledBox({barWidth, rodTr}, off + 2, 5, colors.white, colors.white)
    end
    
    if gWidth >= 8 then
        drawText(string.format("%6.2f%%", averageRod), off + 4, rodTr > 0 and rodTr + 5 or 6,
                rodTr > 0 and colors.white or colors.yellow, colors.black)
    end
end

local function drawTemperatures(xoff, graphWidth, graphHeight)
    local srf = graphHeight or (sizey - 9)
    local gWidth = graphWidth or 15
    local off = xoff
    local w, h = getScreenSize()
    
    -- Adapter la taille selon l'écran
    gWidth = math.min(gWidth, w - off - 1)
    srf = math.min(srf, h - 6)

    drawBox({gWidth, srf + 2}, off, 4, colors.lightBlue)

    local tempUnit = (reactorVersion == "Bigger Reactors") and "K" or "C"
    local tempFormat = "%4s"..tempUnit

    local fuelRnd = math.floor(averageFuelTemp)
    local caseRnd = math.floor(averageCaseTemp)
    local fuelTr = math.floor(fuelRnd / 2000 * srf)
    local caseTr = math.floor(caseRnd / 2000 * srf)
    
    if gWidth >= 15 then
        drawText("Temperatures", off + 2, 4, colors.black, colors.orange)
        drawText(" Case ", off + 2, 5, colors.gray, colors.lightBlue)
        drawText(" Fuel ", off + 9, 5, colors.gray, colors.magenta)
    elseif gWidth >= 8 then
        drawText("Temps", off + 1, 4, colors.black, colors.orange)
        drawText("C", off + 1, 5, colors.gray, colors.lightBlue)
        drawText("F", off + 5, 5, colors.gray, colors.magenta)
    else
        drawText("T", off + 1, 4, colors.black, colors.orange)
    end
    
    -- Adapter les barres selon la largeur
    local barWidth = math.max(2, math.floor((gWidth - 3) / 2))
    local spacing = gWidth >= 10 and 1 or 0
    
    if (fuelTr > 0) then
        fuelTr = math.min(fuelTr, srf)
        drawFilledBox({barWidth, fuelTr}, off + barWidth + spacing + 1, srf + 5 - fuelTr,
                colors.magenta, colors.magenta)
        
        if gWidth >= 8 then
            drawText(string.format(tempFormat, fuelRnd..""),
                    off + barWidth + spacing + 1, srf + 6 - fuelTr,
                    colors.magenta, colors.black)
        end
    elseif gWidth >= 8 then
        drawText(string.format(tempFormat, fuelRnd..""),
                off + barWidth + spacing + 1, srf + 5,
                colors.black, colors.magenta)
    end

    if (caseTr > 0) then
        caseTr = math.min(caseTr, srf)
        drawFilledBox({barWidth, caseTr}, off + 1, srf + 5 - caseTr,
                colors.lightBlue, colors.lightBlue)
        
        if gWidth >= 8 then
            drawText(string.format(tempFormat, caseRnd..""),
                    off + 3, srf + 6 - caseTr,
                    colors.lightBlue, colors.black)
        end
    elseif gWidth >= 8 then
        drawText(string.format(tempFormat, caseRnd..""),
                off + 3, srf + 5,
                colors.black, colors.lightBlue)
    end

    if gWidth >= 10 then
        drawBox({1, srf}, off + barWidth + 1, 5, colors.gray)
    end
end

local function drawGraph(name, offset, graphWidth, graphHeight)
    if (name == "Energy Buffer") then
        drawEnergyBuffer(offset, graphWidth, graphHeight)
    elseif (name == "Control Level") then
        drawControlLevel(offset, graphWidth, graphHeight)
    elseif (name == "Temperatures") then
        drawTemperatures(offset, graphWidth, graphHeight)
    end
end

-- Interface adaptative selon la taille d'écran
local function drawGraphs()
    local screenType = detectScreenType()
    local w, h = getScreenSize()
    
    if screenType == "pocket" then
        -- Pas de graphiques sur pocket, juste des données textuelles
        local line = 3
        drawText("Energy: " .. string.format("%.1f%%", getPercPower()), 1, line, colors.black, colors.green)
        line = line + 1
        drawText("Rods: " .. string.format("%.0f%%", averageRod), 1, line, colors.black, colors.yellow)
        line = line + 1
        drawText("Gen: " .. format(averageLastRFT), 1, line, colors.black, colors.cyan)
        line = line + 1
        drawText("Use: " .. format(averageRfLost), 1, line, colors.black, colors.red)
        
    elseif screenType == "compact" then
        -- Graphiques réduits pour écrans compacts
        local graphHeight = math.max(6, h - 15)
        local graphWidth = math.max(8, math.floor((w - 6) / 3))
        local spacing = 1
        local currentX = 2
        
        if graphsToDraw["Energy Buffer"] then
            drawEnergyBuffer(currentX, graphWidth, graphHeight)
            currentX = currentX + graphWidth + spacing
        end
        
        if graphsToDraw["Control Level"] and currentX + graphWidth < w - 2 then
            drawControlLevel(currentX, graphWidth, graphHeight)
            currentX = currentX + graphWidth + spacing
        end
        
        if graphsToDraw["Temperatures"] and currentX + graphWidth < w - 2 then
            drawTemperatures(currentX, graphWidth, graphHeight)
        end
        
    else
        -- Code original pour écrans standard et VNC
        for i,v in pairs(graphsToDraw) do
            if (v + 15 < dim) then
                drawGraph(i,v)
            end
        end
    end
end

local function drawStatus()
    local screenType = detectScreenType()
    local w, h = getScreenSize()
    
    if screenType == "pocket" then
        -- Interface pocket ultra-simple
        drawText("Reactor v" .. version, 1, 1, colors.black, colors.white)
        local status = btnOn and "ON" or "OFF"
        local statusColor = btnOn and colors.green or colors.red
        drawText("Status: " .. status, 1, 2, colors.black, statusColor)
        drawGraphs()
        
    elseif screenType == "compact" then
        -- Interface compacte
        drawText("Reactor Controller", 1, 1, colors.black, colors.white)
        local status = btnOn and "Online" or "Offline"
        local statusColor = btnOn and colors.green or colors.red
        drawText("Status: " .. status, 1, 2, colors.black, statusColor)
        
        -- Graphiques compacts
        drawBox({w - 2, h - 10}, 1, 3, colors.lightBlue)
        drawText(" Reactor Data ", 3, 3, colors.black, colors.lightBlue)
        drawGraphs()
        
    else
        -- Interface standard/VNC (code original)
        if (dim <= -1) then
            return
        end
        drawBox({dim, sizey - 2}, 1, 1, colors.lightBlue)
        drawText(" Reactor Graphs ", dim - 18, 2, colors.black, colors.lightBlue)
        drawGraphs()
    end
end

local function drawControls()
    local screenType = detectScreenType()
    local w, h = getScreenSize()
    
    if screenType == "pocket" then
        -- Contrôles minimaux en bas
        drawText(string.format("Min:%d Max:%d", minb, maxb), 1, h - 5, colors.black, colors.purple)
        return
        
    elseif screenType == "compact" then
        -- Contrôles compacts
        local controlY = h - 8
        drawBox({w - 2, 6}, 1, controlY, colors.cyan)
        drawText(" Controls ", 3, controlY, colors.black, colors.cyan)
        
        local status = btnOn and "Online" or "Offline"
        local statusColor = btnOn and colors.green or colors.red
        drawText("Reactor " .. status, 3, controlY + 1, colors.black, statusColor)
        
        drawText(string.format("Buffer: %d%% - %d%%", minb, maxb), 3, controlY + 3, colors.black, colors.orange)
        
        return
    end
    
    -- Code original pour écrans plus grands
    if (sizey == 24) then
        drawBox({sizex - dim - 3, 9}, dim + 2, oo,
                colors.cyan)
        drawText(" Reactor Controls ", dim + 7, oo + 1,
                colors.black, colors.cyan)
        drawText("Reactor "..(btnOn and "Online" or "Offline"),
                dim + 10, 3 + oo,
                colors.black, btnOn and colors.green or colors.red)
        return
    end

    drawBox({sizex - dim - 3, 23}, dim + 2, oo,
            colors.cyan)
    drawText(" Reactor Controls ", dim + 7, oo + 1,
            colors.black, colors.cyan)
    drawFilledBox({20, 3}, dim + 7, 8 + oo,
            colors.red, colors.red)
    drawFilledBox({(maxb - minb) / 5, 3},
            dim + 7 + minb / 5, 8 + oo,
            colors.green, colors.green)
    drawText(string.format("%3s", minb.."%"), dim + 6 + minb / 5, 12 + oo,
            colors.black, colors.purple)
    drawText(maxb.."%", dim + 8 + maxb / 5, 12 + oo,
            colors.black, colors.magenta)
    drawText("Buffer Target Range", dim + 8, 8 + oo,
            colors.black, colors.orange)
    drawText("Min", dim + 10, 14 + oo,
            colors.black, colors.purple)
    drawText("Max", dim + 22, 14 + oo,
            colors.black, colors.magenta)
    drawText("Reactor ".. (btnOn and "Online" or "Offline"),
            dim + 10, 3 + oo,
            colors.black, btnOn and colors.green or colors.red)
end

local function drawStatistics()
    local screenType = detectScreenType()
    local w, h = getScreenSize()
    
    if screenType == "pocket" then
        -- Pas de section statistiques séparée
        return
        
    elseif screenType == "compact" then
        -- Statistiques compactes
        local statsY = h - 2
        drawText("Gen:" .. format(averageLastRFT) .. " Use:" .. format(averageRfLost), 
                1, statsY, colors.black, colors.green)
        return
    end
    
    -- Code original pour écrans plus grands
    local oS = sizey - 13
    drawBox({sizex - dim - 3, sizey - oS - 1}, dim + 2, oS,
            colors.blue)
    drawText(" Reactor Statistics ", dim + 7, oS + 1,
            colors.black, colors.blue)

    --statistics
    drawText("Generating : "
            ..format(averageLastRFT).."RF/t", dim + 5, oS + 3,
            colors.black, colors.green)
    drawText("RF Drain   "
            ..(averageStoredThisTick <= averageLastRFT and "> " or ": ")
            ..format(averageRfLost)
            .."RF/t", dim + 5, oS + 5,
            colors.black, colors.red)
    drawText("Efficiency : "
            ..format(getEfficiency()).."RF/B",
            dim + 5, oS + 7,
            colors.black, colors.green)
    drawText("Fuel Usage : "
            ..format(averageFuelUsage)
            .."B/t", dim + 5, oS + 9,
            colors.black, colors.green)
    drawText("Waste      : "
            ..string.format("%7d mB", waste),
            dim + 5, oS + 11,
            colors.black, colors.green)
end

--Draw a scene - adaptative
local function drawScene()
    local output = getOutput()
    if not output then return end
    
    local screenType = detectScreenType()
    
    if screenType == "pocket" or screenType == "compact" then
        -- Interface simplifiée pour petits écrans
        resetMon()
        drawStatus()
        drawControls()
        drawStatistics()
        if t then t:draw() end
        return
    end
    
    -- Code original pour écrans standards
    if (invalidDim) then
        output.write("Invalid Monitor Dimensions")
        return
    end

    if (displayingGraphMenu) then
        drawGraphButtons()
    end
    drawControls()
    drawStatus()
    drawStatistics()
    if t then t:draw() end
end

--returns the side that a given peripheral type is connected to
local function getPeripheral(name)
    for i,v in pairs(peripheral.getNames()) do
        if (peripheral.getType(v) == name) then
            return v
        end
    end
    return ""
end

--Creates all the buttons and determines monitor size - adaptative
local function initMon()
    local screenType = detectScreenType()
    
    -- Détecter si on utilise un moniteur ou le terminal
    monSide = getPeripheral("monitor")
    if (monSide == nil or monSide == "") then
        monSide = nil
        -- Utiliser le terminal principal
        sizex, sizey = term.getSize()
    else
        mon = peripheral.wrap(monSide)
        if mon == nil then
            monSide = nil
            sizex, sizey = term.getSize()
        else
            sizex, sizey = mon.getSize()
        end
    end

    resetMon()
    t = touchpoint.new(monSide)
    
    -- Adapter les calculs selon la taille d'écran
    if screenType == "pocket" or screenType == "compact" then
        oo = 1
        dim = sizex - 10  -- Moins d'espace réservé
    else
        oo = sizey - 37
        dim = sizex - 33
        if (sizex == 36) then
            dim = -1
        end
    end
    
    -- Essayer d'ajouter les boutons de graphiques si possible
    if screenType == "standard" and pcall(addGraphButtons) then
        displayingGraphMenu = true
    else
        t = touchpoint.new(monSide)
        displayingGraphMenu = false
    end
    
    -- Ajouter les boutons principaux
    local rtn = pcall(addButtons)
    if (not rtn) then
        t = touchpoint.new(monSide)
        invalidDim = true
    else
        invalidDim = false
    end
end

-- Fonctions de contrôle et données (identiques au code original)
local function setRods(level)
    level = math.max(level, 0)
    level = math.min(level, 100)
    reactor.setAllControlRodLevels(level)
end

local function lerp(start, finish, t)
    t = math.max(0, math.min(1, t))
    return (1 - t) * start + t * finish
end

local function calculateAverage(array)
    local sum = 0
    for _, value in ipairs(array) do
        sum = sum + value
    end
    return sum / #array
end

local pid = {
    setpointRFT = 0,
    setpointRF = 0,
    Kp = -.08,
    Ki = -.0015,
    Kd = -.01,
    integral = 0,
    lastError = 0,
}

local function iteratePID(pid, error)
    local P = pid.Kp * error
    pid.integral = pid.integral + pid.Ki * error
    pid.integral = math.max(math.min(100, pid.integral), -100)
    local derivative = pid.Kd * (error - pid.lastError)
    local rodLevel = math.max(math.min(P + pid.integral + derivative, 100), 0)
    pid.lastError = error
    return rodLevel
end

local function updateRods()
    if (not btnOn) then
        return
    end
    local currentRF = storedThisTick
    local diffb = maxb - minb
    local minRF = minb / 100 * capacity
    local diffRF = diffb / 100 * capacity
    local diffr = diffb / 100
    local targetRFT = rfLost
    local currentRFT = lastRFT
    local targetRF = diffRF / 2 + minRF

    pid.setpointRFT = targetRFT
    pid.setpointRF = targetRF / capacity * 1000

    local errorRFT = pid.setpointRFT - currentRFT
    local errorRF = pid.setpointRF - currentRF / capacity * 1000

    local W_RFT = lerp(1, 0, (math.abs(targetRF - currentRF) / capacity / (diffr / 4)))
    W_RFT = math.max(math.min(W_RFT, 1), 0)

    local W_RF = (1 - W_RFT)
    local combinedError = W_RFT * errorRFT + W_RF * errorRF
    local error = combinedError
    local rftRodLevel = iteratePID(pid, error)

    setRods(rftRodLevel)
end

local function saveToConfig()
    local file = fs.open(tag.."Serialized.txt", "w")
    local configs = {
        maxb = maxb,
        minb = minb,
        rod = rod,
        btnOn = btnOn,
        graphsToDraw = graphsToDraw,
        XOffs = XOffs,
    }
    local serialized = textutils.serialize(configs)
    file.write(serialized)
    file.close()
end

local storedThisTickValues = {}
local lastRFTValues = {}
local rodValues = {}
local fuelUsageValues = {}
local wasteValues = {}
local fuelTempValues = {}
local caseTempValues = {}
local rfLostValues = {}

local function updateStats()
    storedLastTick = storedThisTick
    if (reactorVersion == "Big Reactors") then
        storedThisTick = reactor.getEnergyStored()
        lastRFT = reactor.getEnergyProducedLastTick()
        rod = reactor.getControlRodLevel(0)
        fuelUsage = reactor.getFuelConsumedLastTick() / 1000
        waste = reactor.getWasteAmount()
        fuelTemp = reactor.getFuelTemperature()
        caseTemp = reactor.getCasingTemperature()
        capacity = math.max(capacity, reactor.getEnergyStored)
    elseif (reactorVersion == "Extreme Reactors") then
        local bat = reactor.getEnergyStats()
        local fuel = reactor.getFuelStats()

        storedThisTick = bat.energyStored
        lastRFT = bat.energyProducedLastTick
        capacity = bat.energyCapacity
        rod = reactor.getControlRodLevel(0)
        fuelUsage = fuel.fuelConsumedLastTick / 1000
        waste = reactor.getWasteAmount()
        fuelTemp = reactor.getFuelTemperature()
        caseTemp = reactor.getCasingTemperature()
    elseif (reactorVersion == "Bigger Reactors") then
        storedThisTick = reactor.battery().stored()
        lastRFT = reactor.battery().producedLastTick()
        capacity = reactor.battery().capacity()
        rod = reactor.getControlRod(0).level()
        fuelUsage = reactor.fuelTank().burnedLastTick() / 1000
        waste = reactor.fuelTank().waste()
        fuelTemp = reactor.fuelTemperature()
        caseTemp = reactor.casingTemperature()
    end
    rfLost = lastRFT + storedLastTick - storedThisTick
    
    table.insert(storedThisTickValues, storedThisTick)
    table.insert(lastRFTValues, lastRFT)
    table.insert(rodValues, rod)
    table.insert(fuelUsageValues, fuelUsage)
    table.insert(wasteValues, waste)
    table.insert(fuelTempValues, fuelTemp)
    table.insert(caseTempValues, caseTemp)
    table.insert(rfLostValues, rfLost)

    local maxIterations = 20 * secondsToAverage
    while #storedThisTickValues > maxIterations do
        table.remove(storedThisTickValues, 1)
        table.remove(lastRFTValues, 1)
        table.remove(rodValues, 1)
        table.remove(fuelUsageValues, 1)
        table.remove(wasteValues, 1)
        table.remove(fuelTempValues, 1)
        table.remove(caseTempValues, 1)
        table.remove(rfLostValues, 1)
    end

    averageStoredThisTick = calculateAverage(storedThisTickValues)
    averageLastRFT = calculateAverage(lastRFTValues)
    averageRod = calculateAverage(rodValues)
    averageFuelUsage = calculateAverage(fuelUsageValues)
    averageWaste = calculateAverage(wasteValues)
    averageFuelTemp = calculateAverage(fuelTempValues)
    averageCaseTemp = calculateAverage(caseTempValues)
    averageRfLost = calculateAverage(rfLostValues)
end

local function loadFromConfig()
    invalidDim = false
    local legacyConfigExists = fs.exists(tag..".txt")
    local newConfigExists = fs.exists(tag.."Serialized.txt")
    if (newConfigExists) then
        local file = fs.open(tag.."Serialized.txt", "r")
        print("Config file "..tag.."Serialized.txt found! Using configurated settings")

        local serialized = file.readAll()
        local deserialized = textutils.unserialise(serialized)
        
        maxb = deserialized.maxb
        minb = deserialized.minb
        rod = deserialized.rod
        btnOn = deserialized.btnOn
        graphsToDraw = deserialized.graphsToDraw
        XOffs = deserialized.XOffs
        file.close()
    elseif (legacyConfigExists) then
        local file = fs.open(tag..".txt", "r")
        local calibrated = file.readLine() == "true"

        if (calibrated) then
            _ = tonumber(file.readLine())
            _ = tonumber(file.readLine())
        end
        maxb = tonumber(file.readLine())
        minb = tonumber(file.readLine())
        rod = tonumber(file.readLine())
        btnOn = file.readLine() == "true"

        for i in pairs(XOffs) do
            local graph = file.readLine()
            local v1 = tonumber(file.readLine())
            local v2 = true
            if (graph ~= "nil") then
                v2 = false
                graphsToDraw[graph] = v1
            end
            XOffs[i] = {v1, v2}
        end
        file.close()
    else
        print("Config file not found, generating default settings!")

        maxb = 70
        minb = 30
        rod = 80
        btnOn = false
        if (monSide == nil) then
            btnOn = true
        end
        sizex, sizey = 100, 52
        dim = sizex - 33
        oo = sizey - 37
        enableGraph("Energy Buffer")
        enableGraph("Control Level")
        enableGraph("Temperatures")
    end
    btnOff = not btnOn
    reactor.setActive(btnOn)
end

local function startTimer(ticksToUpdate, callback)
    local timeToUpdate = ticksToUpdate * 0.05
    local id = os.startTimer(timeToUpdate)
    local fun = function(event)
        if (event[1] == "timer" and event[2] == id) then
            id = os.startTimer(timeToUpdate)
            callback()
        end
    end
    return fun
end

-- Boucle principale adaptative
local function loop()
    local ticksToUpdateStats = 1
    local ticksToRedraw = 4
    
    local hasClicked = false

    local updateStatsTick = startTimer(
        ticksToUpdateStats,
        function()
            updateStats()
            updateRods()
        end
    )
    local redrawTick = startTimer(
        ticksToRedraw,
        function()
            if (not hasClicked) then
                resetMon()
                drawScene()
            end
            hasClicked = false
        end
    )
    local handleResize = function(event)
        if (event[1] == "monitor_resize" or event[1] == "term_resize") then
            initMon()
        end
    end
    local handleClick = function(event)
        if (event[1] == "button_click") then
            if t and t.buttonList and t.buttonList[event[2]] then
                t.buttonList[event[2]].func()
                saveToConfig()
                resetMon()
                drawScene()
                hasClicked = true
            end
        end
    end
    
    while (true) do
        local event
        if t then
            event = { t:handleEvents() }
        else
            event = { os.pullEvent() }
        end

        updateStatsTick(event)
        redrawTick(event)
        handleResize(event)
        handleClick(event)
        
        -- Gestion des événements clavier pour VNC/terminal
        if event[1] == "key" then
            if event[2] == keys.q or event[2] == keys.x then
                break
            elseif event[2] == keys.r then
                if btnOn then turnOff() else turnOn() end
            end
        elseif event[1] == "terminate" then
            break
        end
    end
end

local function detectReactor()
    local reactor_bigger_v1 = getPeripheral("bigger-reactor")
    reactor = reactor_bigger_v1 ~= nil and peripheral.wrap(reactor_bigger_v1)
    if (reactor ~= nil) then
        reactorVersion = "Bigger Reactors"
        return true
    end

    local reactor_bigger_v2 = getPeripheral("BiggerReactors_Reactor")
    reactor = reactor_bigger_v2 ~= nil and peripheral.wrap(reactor_bigger_v2)
    if (reactor ~= nil) then
        reactorVersion = "Bigger Reactors"
        return true
    end

    local reactor_extreme_or_big = getPeripheral("BigReactors-Reactor")
    reactor = reactor_extreme_or_big ~= nil and peripheral.wrap(reactor_extreme_or_big)
    if (reactor ~= nil) then
        reactorVersion = (reactor.mbIsConnected ~= nil) and "Extreme Reactors" or "Big Reactors"
        return true
    end
    return false
end

local function main()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1,1)

    local reactorDetected = false
    while (not reactorDetected) do
        reactorDetected = detectReactor()
        if (not reactorDetected) then
            print("Reactor not detected! Trying again...")
            sleep(1)
        end
    end
    
    print("Reactor detected! Proceeding with initialization ")
    print("Reactor Type: " .. reactorVersion)

    print("Loading config...")
    loadFromConfig()
    print("Initializing interface...")
    initMon()
    print("Writing config to disk...")
    saveToConfig()
    print("Reactor initialization done! Starting controller")
    
    local screenType = detectScreenType()
    print("Screen Type: " .. screenType)
    print("Screen Size: " .. sizex .. "x" .. sizey)
    
    sleep(2)

    term.clear()
    term.setCursorPos(1,1)
    print("Reactor Controller Version "..version)
    print("Reactor Mod: "..reactorVersion)
    print("Press 'q' to quit, 'r' to toggle reactor")
    sleep(1)

    loop()
end

main()

print("Reactor Controller stopped")
sleep(1)