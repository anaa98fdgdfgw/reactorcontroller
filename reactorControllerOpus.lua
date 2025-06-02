local Config = require('opus.config')

local version = "0.61"
local appId = "reactorController"

-- Configuration par défaut
local config = Config.load(appId, {
    maxb = 70,
    minb = 30,
    rod = 80,
    reactorActive = false,
    secondsToAverage = 2,
    pidSettings = {
        Kp = -0.08,
        Ki = -0.0015,
        Kd = -0.01,
    },
    graphsEnabled = {
        ["Energy Buffer"] = true,
        ["Control Level"] = true,
        ["Temperatures"] = true,
    }
})

local reactorVersion, reactor
local storedLastTick, storedThisTick, lastRFT = 0, 0, 0
local fuelTemp, caseTemp, fuelUsage, waste, capacity = 0, 0, 0, 0, 1
local rfLost = 0

-- Stockage des moyennes
local averageStoredThisTick = 0
local averageLastRFT = 0
local averageRod = 0
local averageFuelUsage = 0
local averageWaste = 0
local averageFuelTemp = 0
local averageCaseTemp = 0
local averageRfLost = 0

-- Arrays pour les moyennes mobiles
local storedThisTickValues = {}
local lastRFTValues = {}
local rodValues = {}
local fuelUsageValues = {}
local wasteValues = {}
local fuelTempValues = {}
local caseTempValues = {}
local rfLostValues = {}

-- PID Controller
local pid = {
    setpointRFT = 0,
    setpointRF = 0,
    Kp = config.pidSettings.Kp,
    Ki = config.pidSettings.Ki,
    Kd = config.pidSettings.Kd,
    integral = 0,
    lastError = 0,
}

-- Variables d'interface
local w, h = term.getSize()
local running = true
local scrollOffset = 0
local maxScroll = 0
local buttons = {}

-- Fonction utilitaire pour détecter le type d'écran
local function detectScreenType()
    local w, h = term.getSize()
    
    if w <= 26 and h <= 20 then
        return "pocket"
    elseif w < 100 or h < 40 then
        return "vnc"
    else
        return "standard"
    end
end

-- Système de boutons tactiles amélioré
local function addButton(name, x, y, width, height, callback, bgColor, textColor, text)
    -- Assurer que le bouton reste dans les limites de l'écran
    if x < 1 then x = 1 end
    if y < 1 then y = 1 end
    if x + width - 1 > w then width = w - x + 1 end
    if y + height - 1 > h then height = h - y + 1 end
    
    buttons[name] = {
        x = x,
        y = y,
        width = width,
        height = height,
        callback = callback,
        bgColor = bgColor or colors.gray,
        textColor = textColor or colors.white,
        text = text or name,
        active = false
    }
end

local function clearButtons()
    buttons = {}
end

local function drawButton(name)
    local btn = buttons[name]
    if not btn then return end
    
    local color = btn.active and colors.lime or btn.bgColor
    local textColor = btn.active and colors.black or btn.textColor
    
    -- Dessiner le bouton
    term.setBackgroundColor(color)
    for y = btn.y, math.min(btn.y + btn.height - 1, h) do
        if y >= 1 then
            term.setCursorPos(btn.x, y)
            term.write(string.rep(" ", math.min(btn.width, w - btn.x + 1)))
        end
    end
    
    -- Centrer le texte
    local textX = btn.x + math.floor((btn.width - #btn.text) / 2)
    local textY = btn.y + math.floor(btn.height / 2)
    
    if textY >= 1 and textY <= h and textX >= 1 and textX <= w then
        term.setCursorPos(textX, textY)
        term.setTextColor(textColor)
        term.write(btn.text:sub(1, math.min(#btn.text, w - textX + 1)))
    end
end

local function handleButtonClick(x, y)
    for name, btn in pairs(buttons) do
        if x >= btn.x and x <= btn.x + btn.width - 1 and
           y >= btn.y and y <= btn.y + btn.height - 1 then
            if btn.callback then
                btn.callback()
            end
            return true
        end
    end
    return false
end

-- Fonctions utilitaires (identiques à l'original)
local function getPeripheral(name)
    for _, v in pairs(peripheral.getNames()) do
        if peripheral.getType(v) == name then
            return v
        end
    end
    return nil
end

local function detectReactor()
    local reactorTypes = {
        { "bigger-reactor", "Bigger Reactors" },
        { "BiggerReactors_Reactor", "Bigger Reactors" },
        { "BigReactors-Reactor", nil }
    }
    
    for _, reactorType in ipairs(reactorTypes) do
        local side = getPeripheral(reactorType[1])
        if side then
            reactor = peripheral.wrap(side)
            if reactorType[2] then
                reactorVersion = reactorType[2]
            else
                reactorVersion = reactor.mbIsConnected and "Extreme Reactors" or "Big Reactors"
            end
            return true
        end
    end
    return false
end

local function format(num)
    if num >= 1000000000 then
        return string.format("%.2fG", num / 1000000000)
    elseif num >= 1000000 then
        return string.format("%.2fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.2fK", num / 1000)
    elseif num >= 1 then
        return string.format("%.2f", num)
    elseif num >= 0.001 then
        return string.format("%.2fm", num * 1000)
    elseif num >= 0.000001 then
        return string.format("%.2fu", num * 1000000)
    else
        return string.format("%.2f", 0)
    end
end

local function calculateAverage(array)
    if #array == 0 then return 0 end
    local sum = 0
    for _, value in ipairs(array) do
        sum = sum + value
    end
    return sum / #array
end

local function updateStats()
    storedLastTick = storedThisTick
    
    if reactorVersion == "Big Reactors" then
        storedThisTick = reactor.getEnergyStored()
        lastRFT = reactor.getEnergyProducedLastTick()
        rod = reactor.getControlRodLevel(0)
        fuelUsage = reactor.getFuelConsumedLastTick() / 1000
        waste = reactor.getWasteAmount()
        fuelTemp = reactor.getFuelTemperature()
        caseTemp = reactor.getCasingTemperature()
        capacity = math.max(capacity, reactor.getEnergyStored())
    elseif reactorVersion == "Extreme Reactors" then
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
    elseif reactorVersion == "Bigger Reactors" then
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
    
    -- Ajouter aux arrays et maintenir la taille
    local maxIterations = 20 * config.secondsToAverage
    
    table.insert(storedThisTickValues, storedThisTick)
    table.insert(lastRFTValues, lastRFT)
    table.insert(rodValues, rod)
    table.insert(fuelUsageValues, fuelUsage)
    table.insert(wasteValues, waste)
    table.insert(fuelTempValues, fuelTemp)
    table.insert(caseTempValues, caseTemp)
    table.insert(rfLostValues, rfLost)
    
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
    
    -- Calculer les moyennes
    averageStoredThisTick = calculateAverage(storedThisTickValues)
    averageLastRFT = calculateAverage(lastRFTValues)
    averageRod = calculateAverage(rodValues)
    averageFuelUsage = calculateAverage(fuelUsageValues)
    averageWaste = calculateAverage(wasteValues)
    averageFuelTemp = calculateAverage(fuelTempValues)
    averageCaseTemp = calculateAverage(caseTempValues)
    averageRfLost = calculateAverage(rfLostValues)
end

local function lerp(start, finish, t)
    t = math.max(0, math.min(1, t))
    return (1 - t) * start + t * finish
end

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
    if not config.reactorActive then return end
    
    local currentRF = storedThisTick
    local diffb = config.maxb - config.minb
    local minRF = config.minb / 100 * capacity
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
    local rftRodLevel = iteratePID(pid, combinedError)
    
    reactor.setAllControlRodLevels(rftRodLevel)
end

-- Fonctions de dessin adaptées
local function drawBox(size, xoff, yoff, color)
    if xoff < 0 or yoff < 0 or xoff >= w or yoff >= h then return end
    
    local x, y = term.getCursorPos()
    term.setBackgroundColor(color)
    local horizLine = string.rep(" ", math.min(size[1], w - xoff))
    
    if yoff + 1 >= 1 and yoff + 1 <= h then
        term.setCursorPos(xoff + 1, yoff + 1)
        term.write(horizLine)
    end
    
    if yoff + size[2] >= 1 and yoff + size[2] <= h then
        term.setCursorPos(xoff + 1, yoff + size[2])
        term.write(horizLine)
    end

    for i = 0, size[2] - 1 do
        local lineY = yoff + i + 1
        if lineY >= 1 and lineY <= h then
            if xoff + 1 >= 1 and xoff + 1 <= w then
                term.setCursorPos(xoff + 1, lineY)
                term.write(" ")
            end
            if xoff + size[1] >= 1 and xoff + size[1] <= w then
                term.setCursorPos(xoff + size[1], lineY)
                term.write(" ")
            end
        end
    end
    term.setCursorPos(x, y)
    term.setBackgroundColor(colors.black)
end

local function drawFilledBox(size, xoff, yoff, colorOut, colorIn)
    if xoff < 0 or yoff < 0 or xoff >= w or yoff >= h then return end
    
    local horizLine = string.rep(" ", math.max(0, math.min(size[1] - 2, w - xoff - 1)))
    drawBox(size, xoff, yoff, colorOut)
    local x, y = term.getCursorPos()
    term.setBackgroundColor(colorIn)
    for i = 2, size[2] - 1 do
        local lineY = yoff + i
        if lineY >= 1 and lineY <= h and xoff + 2 >= 1 and xoff + 2 <= w then
            term.setCursorPos(xoff + 2, lineY)
            term.write(horizLine)
        end
    end
    term.setBackgroundColor(colors.black)
    term.setCursorPos(x, y)
end

local function drawText(text, x1, y1, backColor, textColor)
    if x1 < 1 or y1 < 1 or x1 > w or y1 > h then return end
    
    local x, y = term.getCursorPos()
    term.setCursorPos(x1, y1)
    term.setBackgroundColor(backColor)
    term.setTextColor(textColor)
    local maxLen = math.max(0, w - x1 + 1)
    term.write(text:sub(1, maxLen))
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.setCursorPos(x, y)
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

-- Callbacks des boutons
local function toggleReactor()
    config.reactorActive = not config.reactorActive
    reactor.setActive(config.reactorActive)
    Config.update(appId, config)
end

local function minPlus10()
    if config.minb < config.maxb - 10 then
        config.minb = math.min(config.maxb - 10, config.minb + 10)
        Config.update(appId, config)
    end
end

local function minMinus10()
    if config.minb > 0 then
        config.minb = math.max(0, config.minb - 10)
        Config.update(appId, config)
    end
end

local function minPlus1()
    if config.minb < config.maxb - 1 then
        config.minb = math.min(config.maxb - 1, config.minb + 1)
        Config.update(appId, config)
    end
end

local function minMinus1()
    if config.minb > 0 then
        config.minb = math.max(0, config.minb - 1)
        Config.update(appId, config)
    end
end

local function maxPlus10()
    if config.maxb < 100 then
        config.maxb = math.min(100, config.maxb + 10)
        Config.update(appId, config)
    end
end

local function maxMinus10()
    if config.maxb > config.minb + 10 then
        config.maxb = math.max(config.minb + 10, config.maxb - 10)
        Config.update(appId, config)
    end
end

local function maxPlus1()
    if config.maxb < 100 then
        config.maxb = math.min(100, config.maxb + 1)
        Config.update(appId, config)
    end
end

local function maxMinus1()
    if config.maxb > config.minb + 1 then
        config.maxb = math.max(config.minb + 1, config.maxb - 1)
        Config.update(appId, config)
    end
end

local function exitApp()
    running = false
end

-- Graphiques adaptés à la taille d'écran avec largeur réduite pour VNC
local function drawEnergyBuffer(xoff, graphWidth, graphHeight)
    local off = xoff
    local srf = graphHeight - 2
    
    -- Cadre principal
    drawBox({graphWidth, srf + 2}, off - 1, 4, colors.lightBlue)
    
    -- Titre adapté
    local title = graphWidth >= 15 and "Energy Buffer" or (graphWidth >= 10 and "Energy" or "Enrg")
    drawText(title, off + 1, 4, colors.black, colors.orange)
    
    -- Fond rouge (vide) - LARGEUR RÉDUITE pour effet barre
    local innerWidth = math.max(2, math.floor(graphWidth * 0.6)) -- RÉDUIT de graphWidth-2 à 60% de la largeur
    local barX = off + math.floor((graphWidth - innerWidth) / 2) -- CENTRÉ
    drawFilledBox({innerWidth, srf}, barX, 5, colors.red, colors.red)
    
    -- Calcul du niveau d'énergie
    local pwr = math.floor(getPercPower() / 100 * srf)
    local rndpw = rnd(getPercPower(), 2)
    
    -- Couleur selon le niveau
    local color = (rndpw < config.maxb and rndpw > config.minb) and colors.green
            or (rndpw >= config.maxb and colors.orange or colors.blue)
    
    -- Partie remplie (verte) - CENTRÉE
    if pwr > 0 then
        drawFilledBox({innerWidth, pwr + 1}, barX, srf + 4 - pwr, color, color)
    end
    
    -- Affichage des valeurs adapté - REPOSITIONNÉ pour la barre centrée
    if graphWidth >= 12 then
        drawText(string.format("%.1fM", averageStoredThisTick / 1000000), 
                off + 1, srf + 5 - math.max(pwr, 3), 
                pwr > 3 and color or colors.red, colors.black)
        
        drawText(string.format("%.1f%%", rndpw), 
                off + graphWidth - 6, srf + 5 - math.max(pwr, 1), 
                pwr > 1 and color or colors.red, colors.black)
    elseif graphWidth >= 8 then
        drawText(string.format("%.0f%%", rndpw), 
                off + 1, srf + 5 - math.max(pwr, 1), 
                pwr > 1 and color or colors.red, colors.black)
    end
end

local function drawControlLevel(xoff, graphWidth, graphHeight)
    local off = xoff
    local srf = graphHeight - 2
    
    -- Cadre principal
    drawBox({graphWidth, srf + 2}, off - 1, 4, colors.lightBlue)
    
    -- Titre adapté
    local title = graphWidth >= 15 and "Control Level" or (graphWidth >= 10 and "Control" or "Ctrl")
    drawText(title, off + 1, 4, colors.black, colors.orange)
    
    -- Fond jaune - LARGEUR RÉDUITE pour effet barre
    local innerWidth = math.max(2, math.floor(graphWidth * 0.6)) -- RÉDUIT à 60% de la largeur
    local barX = off + math.floor((graphWidth - innerWidth) / 2) -- CENTRÉ
    drawFilledBox({innerWidth, srf}, barX, 5, colors.yellow, colors.yellow)
    
    -- Calcul du niveau des barres
    local rodTr = math.floor(averageRod / 100 * srf)
    
    -- Barres blanches (niveau des barres de contrôle) - CENTRÉES et plus étroites
    if rodTr > 0 then
        local rodBarWidth = math.max(1, math.floor(innerWidth * 0.8)) -- 80% de la barre de fond
        local rodBarOffset = barX + math.floor((innerWidth - rodBarWidth) / 2)
        drawFilledBox({rodBarWidth, rodTr}, rodBarOffset, 5, colors.white, colors.white)
    end
    
    -- Affichage du pourcentage
    if graphWidth >= 8 then
        drawText(string.format("%.0f%%", averageRod), 
                off + 1, rodTr > 2 and rodTr + 5 or 6,
                rodTr > 2 and colors.white or colors.yellow, colors.black)
    end
end

local function drawTemperatures(xoff, graphWidth, graphHeight)
    local off = xoff
    local srf = graphHeight - 2
    
    -- Cadre principal  
    drawBox({graphWidth, srf + 2}, off, 4, colors.lightBlue)
    
    -- Titre adapté
    local title = graphWidth >= 15 and "Temperatures" or (graphWidth >= 10 and "Temps" or "Temp")
    drawText(title, off + 1, 4, colors.black, colors.orange)
    
    local tempUnit = (reactorVersion == "Bigger Reactors") and "K" or "C"

    local fuelRnd = math.floor(averageFuelTemp)
    local caseRnd = math.floor(averageCaseTemp)
    local fuelTr = math.floor(fuelRnd / 2000 * srf)
    local caseTr = math.floor(caseRnd / 2000 * srf)
    
    -- Adapter la largeur des barres - PLUS ÉTROITES pour effet barre
    local totalBarWidth = math.floor(graphWidth * 0.6) -- 60% de la largeur totale
    local barWidth = math.max(1, math.floor(totalBarWidth / 2)) -- Diviser en 2 barres
    local spacing = math.max(1, totalBarWidth - (barWidth * 2)) -- Espacement central
    local startX = off + math.floor((graphWidth - totalBarWidth) / 2) + 1 -- Centrer les barres
    
    -- Labels adaptés - REPOSITIONNÉS
    if graphWidth >= 10 then
        drawText("Case", startX, 5, colors.gray, colors.lightBlue)
        drawText("Fuel", startX + barWidth + spacing, 5, colors.gray, colors.magenta)
    else
        drawText("C", startX, 5, colors.gray, colors.lightBlue)
        drawText("F", startX + barWidth + spacing, 5, colors.gray, colors.magenta)
    end
    
    -- Barre de température du boîtier - PLUS ÉTROITE
    if caseTr > 0 then
        caseTr = math.min(caseTr, srf)
        drawFilledBox({barWidth, caseTr}, startX, srf + 5 - caseTr,
                colors.lightBlue, colors.lightBlue)
    end
    
    -- Barre de température du combustible - PLUS ÉTROITE
    if fuelTr > 0 then
        fuelTr = math.min(fuelTr, srf)
        drawFilledBox({barWidth, fuelTr}, startX + barWidth + spacing, srf + 5 - fuelTr,
                colors.magenta, colors.magenta)
    end
    
    -- Affichage des valeurs si l'espace le permet - REPOSITIONNÉES
    if graphWidth >= 8 then
        drawText(string.format("%d", caseRnd),
                startX, srf + 5 - math.max(caseTr, 1),
                caseTr > 1 and colors.lightBlue or colors.black, colors.black)
        
        drawText(string.format("%d", fuelRnd),
                startX + barWidth + spacing, srf + 5 - math.max(fuelTr, 1),
                fuelTr > 1 and colors.magenta or colors.black, colors.black)
    end
end

-- Interface adaptative avec disposition améliorée
local function drawInterface()
    term.setBackgroundColor(colors.black)
    term.clear()
    clearButtons()
    
    w, h = term.getSize()
    local screenType = detectScreenType()
    
    if screenType == "pocket" then
        -- Interface pocket avec boutons tactiles (inchangée)
        local line = 1 - scrollOffset
        
        local function addLine(text, color)
            if line >= 1 and line <= h - 4 then
                drawText(text, 1, line, colors.black, color or colors.white)
            end
            line = line + 1
            return line - 1
        end
        
        addLine("Reactor v" .. version, colors.yellow)
        line = line + 1
        
        local status = config.reactorActive and "ONLINE" or "OFFLINE"
        local statusColor = config.reactorActive and colors.green or colors.red
        addLine("Status: " .. status, statusColor)
        
        local energyPercent = capacity > 0 and (averageStoredThisTick / capacity * 100) or 0
        addLine(string.format("Energy: %.1f%%", energyPercent), colors.cyan)
        addLine(format(averageStoredThisTick) .. "RF", colors.cyan)
        line = line + 1
        
        addLine("Gen: " .. format(averageLastRFT) .. "RF/t", colors.green)
        addLine("Use: " .. format(averageRfLost) .. "RF/t", colors.red)
        line = line + 1
        
        addLine(string.format("Rods: %.1f%%", averageRod), colors.purple)
        line = line + 1
        
        local tempUnit = (reactorVersion == "Bigger Reactors") and "K" or "C"
        addLine(string.format("Case: %d%s", math.floor(averageCaseTemp), tempUnit), colors.lightBlue)
        addLine(string.format("Fuel: %d%s", math.floor(averageFuelTemp), tempUnit), colors.magenta)
        line = line + 1
        
        -- Affichage des valeurs Min/Max
        addLine(string.format("Min: %d%%", config.minb), colors.purple)
        addLine(string.format("Max: %d%%", config.maxb), colors.magenta)
        
        maxScroll = math.max(0, line - h + 4)
        
        -- Boutons en bas
        local buttonY = h - 3
        local buttonWidth = math.floor(w / 6)
        
        addButton("toggle", 1, buttonY, buttonWidth * 2, 2, toggleReactor,
                config.reactorActive and colors.red or colors.green, colors.white,
                config.reactorActive and "OFF" or "ON")
        
        addButton("minMinus", buttonWidth * 2 + 1, buttonY, buttonWidth, 2, minMinus1, colors.purple, colors.white, "M-")
        addButton("minPlus", buttonWidth * 3 + 1, buttonY, buttonWidth, 2, minPlus1, colors.purple, colors.white, "M+")
        addButton("maxMinus", buttonWidth * 4 + 1, buttonY, buttonWidth, 2, maxMinus1, colors.magenta, colors.white, "X-")
        addButton("maxPlus", buttonWidth * 5 + 1, buttonY, w - buttonWidth * 5, 2, maxPlus1, colors.magenta, colors.white, "X+")
        
        -- Boutons de navigation
        addButton("up", 1, buttonY - 2, buttonWidth, 1, 
                function() scrollOffset = math.max(0, scrollOffset - 3) end, 
                colors.blue, colors.white, "UP")
        
        addButton("down", buttonWidth + 1, buttonY - 2, buttonWidth, 1, 
                function() scrollOffset = math.min(maxScroll, scrollOffset + 3) end, 
                colors.blue, colors.white, "DOWN")
        
        addButton("exit", w - 6, buttonY - 2, 6, 1, exitApp, colors.red, colors.white, "EXIT")
        
    elseif screenType == "vnc" then
        -- Interface VNC avec graphiques EN BARRES ÉTROITES
        
        -- === SECTION 1: GRAPHIQUES (TOP) - LARGEUR RÉDUITE ===
        local graphStartY = 2
        local graphHeight = math.max(6, math.min(8, math.floor(h * 0.25)))
        
        -- Calculer nombre et largeur des graphiques - LARGEUR RÉDUITE
        local numGraphs = 0
        if config.graphsEnabled["Energy Buffer"] then numGraphs = numGraphs + 1 end
        if config.graphsEnabled["Control Level"] then numGraphs = numGraphs + 1 end
        if config.graphsEnabled["Temperatures"] then numGraphs = numGraphs + 1 end
        
        if numGraphs > 0 then
            local spacing = 2 -- ESPACEMENT AUGMENTÉ pour séparer les barres
            local totalSpacing = (numGraphs - 1) * spacing
            local availableWidth = w - 8 - totalSpacing -- LARGEUR TOTALE RÉDUITE
            local graphWidth = math.max(8, math.min(12, math.floor(availableWidth / numGraphs))) -- LARGEUR LIMITÉE pour effet barre
            
            local graphsStartX = 4 + math.floor((w - 8 - (graphWidth * numGraphs + totalSpacing)) / 2) -- CENTRER les graphiques
            local totalGraphsWidth = (graphWidth * numGraphs) + totalSpacing + 2
            
            -- Cadre principal des graphiques
            drawBox({totalGraphsWidth, graphHeight + 2}, graphsStartX - 1, graphStartY, colors.lightBlue)
            drawText(" Reactor Graphs ", graphsStartX + 2, graphStartY, colors.black, colors.lightBlue)
            
            -- Dessiner les graphiques
            local currentX = graphsStartX
            if config.graphsEnabled["Energy Buffer"] then
                drawEnergyBuffer(currentX, graphWidth, graphHeight)
                currentX = currentX + graphWidth + spacing
            end
            
            if config.graphsEnabled["Control Level"] then
                drawControlLevel(currentX, graphWidth, graphHeight)
                currentX = currentX + graphWidth + spacing
            end
            
            if config.graphsEnabled["Temperatures"] then
                drawTemperatures(currentX, graphWidth, graphHeight)
            end
        end
        
        -- === SECTION 2: CONTRÔLES DU RÉACTEUR (INCHANGÉE) ===
        local controlStartY = graphStartY + graphHeight + 3
        local controlHeight = 4
        local controlWidth = w - 4
        
        -- Contrôles du réacteur
        drawBox({controlWidth, controlHeight}, 2, controlStartY, colors.cyan)
        drawText(" Reactor Controls ", 4, controlStartY, colors.black, colors.cyan)
        
        local status = config.reactorActive and "Online" or "Offline"
        local statusColor = config.reactorActive and colors.green or colors.red
        drawText("Status: " .. status, 4, controlStartY + 1, colors.black, statusColor)
        
        -- Boutons On/Off (ligne 2-3)
        local buttonWidth = math.max(6, math.floor(controlWidth / 8))
        addButton("onButton", 4, controlStartY + 2, buttonWidth, 2, 
                function() 
                    config.reactorActive = true
                    reactor.setActive(true)
                    Config.update(appId, config)
                end, colors.green, colors.white, "Online")
        
        addButton("offButton", 4 + buttonWidth + 2, controlStartY + 2, buttonWidth, 2, 
                function() 
                    config.reactorActive = false
                    reactor.setActive(false)
                    Config.update(appId, config)
                end, colors.red, colors.white, "Offline")
        
        buttons["onButton"].active = config.reactorActive
        buttons["offButton"].active = not config.reactorActive
        
        -- === SECTION 3: BUFFER TARGET RANGE (INCHANGÉE) ===
        local bufferStartY = controlStartY + controlHeight + 1
        local bufferHeight = 5
        
        -- Buffer Target Range
        drawBox({controlWidth, bufferHeight}, 2, bufferStartY, colors.orange)
        drawText(" Buffer Target Range ", 4, bufferStartY, colors.black, colors.orange)
        
        -- Barre de range (ligne 2)
        local rangeBarWidth = math.min(math.floor(controlWidth * 0.7), 30)
        local rangeBarX = 4 + math.floor((controlWidth - rangeBarWidth) / 2)
        
        drawFilledBox({rangeBarWidth, 2}, rangeBarX, bufferStartY + 1, colors.red, colors.red)
        local rangeWidth = math.floor((config.maxb - config.minb) / 100 * (rangeBarWidth - 2))
        local rangeStart = math.floor(config.minb / 100 * (rangeBarWidth - 2))
        drawFilledBox({rangeWidth, 2}, rangeBarX + rangeStart, bufferStartY + 1, colors.green, colors.green)
        
        -- Valeurs Min/Max (ligne 3) - BIEN SÉPARÉES
        local valueY = bufferStartY + 3
        drawText(string.format("Min: %d%%", config.minb), 4, valueY, colors.black, colors.purple)
        drawText(string.format("Max: %d%%", config.maxb), w - 10, valueY, colors.black, colors.magenta)
        
        -- Boutons Min/Max (ligne 4) - BIEN ALIGNÉS ET SÉPARÉS
        local buttonY = bufferStartY + 4
        local btnSize = 3
        
        -- Boutons Min (gauche)
        addButton("minMinus", 4, buttonY, btnSize, 1, minMinus1, colors.purple, colors.white, " - ")
        addButton("minPlus", 4 + btnSize + 1, buttonY, btnSize, 1, minPlus1, colors.purple, colors.white, " + ")
        
        -- Boutons Max (droite) 
        addButton("maxMinus", w - 10, buttonY, btnSize, 1, maxMinus1, colors.magenta, colors.white, " - ")
        addButton("maxPlus", w - 10 + btnSize + 1, buttonY, btnSize, 1, maxPlus1, colors.magenta, colors.white, " + ")
        
        -- === SECTION 4: STATISTIQUES (INCHANGÉE) ===
        local statsStartY = bufferStartY + bufferHeight + 1
        local statsHeight = h - statsStartY - 1
        
        if statsHeight >= 3 then
            drawBox({controlWidth, statsHeight}, 2, statsStartY, colors.blue)
            drawText(" Reactor Statistics ", 4, statsStartY, colors.black, colors.blue)
            
            local statY = statsStartY + 1
            local maxStatsLines = statsHeight - 1
            local statLines = 0
            
            if statLines < maxStatsLines then
                drawText("Generation: " .. format(averageLastRFT) .. "RF/t", 4, statY + statLines, colors.black, colors.green)
                statLines = statLines + 1
            end
            
            if statLines < maxStatsLines then
                drawText("Consumption: " .. format(averageRfLost) .. "RF/t", 4, statY + statLines, colors.black, colors.red)
                statLines = statLines + 1
            end
            
            if statLines < maxStatsLines then
                local efficiency = averageFuelUsage > 0 and averageLastRFT / averageFuelUsage or math.huge
                drawText("Efficiency: " .. (efficiency == math.huge and "inf" or format(efficiency)) .. "RF/B",
                        4, statY + statLines, colors.black, colors.green)
                statLines = statLines + 1
            end
            
            if statLines < maxStatsLines then
                drawText("Fuel Usage: " .. format(averageFuelUsage) .. "B/t", 4, statY + statLines, colors.black, colors.green)
                statLines = statLines + 1
            end
            
            if statLines < maxStatsLines then
                drawText("Waste: " .. string.format("%d mB", math.floor(averageWaste)), 4, statY + statLines, colors.black, colors.green)
            end
        end
        
        -- Bouton exit (coin supérieur droit)
        addButton("exit", w - 6, 1, 6, 1, exitApp, colors.red, colors.white, "EXIT")
        
    else
        -- Interface standard (inchangée)
        local graphHeight = h - 12
        local graphWidth = 17
        local spacing = 2
        
        -- Zone des graphiques (gauche)
        local graphsStartX = 4
        local numGraphs = 0
        if config.graphsEnabled["Energy Buffer"] then numGraphs = numGraphs + 1 end
        if config.graphsEnabled["Control Level"] then numGraphs = numGraphs + 1 end
        if config.graphsEnabled["Temperatures"] then numGraphs = numGraphs + 1 end
        
        local graphsWidth = (graphWidth * numGraphs) + (spacing * (numGraphs - 1)) + 2
        
        -- Cadre principal des graphiques
        drawBox({graphsWidth, graphHeight + 2}, graphsStartX - 1, 4, colors.lightBlue)
        drawText(" Reactor Graphs ", graphsStartX + 5, 4, colors.black, colors.lightBlue)
        
        -- Dessiner les graphiques
        local currentX = graphsStartX
        if config.graphsEnabled["Energy Buffer"] then
            drawEnergyBuffer(currentX, graphWidth, graphHeight)
            currentX = currentX + graphWidth + spacing
        end
        
        if config.graphsEnabled["Control Level"] then
            drawControlLevel(currentX, graphWidth, graphHeight)
            currentX = currentX + graphWidth + spacing
        end
        
        if config.graphsEnabled["Temperatures"] then
            drawTemperatures(currentX, graphWidth, graphHeight)
        end
        
        -- Zone des contrôles (droite)
        local controlX = graphsStartX + graphsWidth + 4
        local controlWidth = w - controlX - 2
        
        -- Contrôles du réacteur
        drawBox({controlWidth, 14}, controlX, 4, colors.cyan)
        drawText(" Reactor Controls ", controlX + 5, 4, colors.black, colors.cyan)
        
        local status = config.reactorActive and "Online" or "Offline"
        local statusColor = config.reactorActive and colors.green or colors.red
        drawText("Reactor " .. status, controlX + 8, 6, colors.black, statusColor)
        
        -- Boutons On/Off
        addButton("onButton", controlX + 3, 8, 8, 3, 
                function() 
                    config.reactorActive = true
                    reactor.setActive(true)
                    Config.update(appId, config)
                end, colors.green, colors.white, "On")
        
        addButton("offButton", controlX + 13, 8, 8, 3, 
                function() 
                    config.reactorActive = false
                    reactor.setActive(false)
                    Config.update(appId, config)
                end, colors.red, colors.white, "Off")
        
        buttons["onButton"].active = config.reactorActive
        buttons["offButton"].active = not config.reactorActive
        
        -- Buffer Target Range
        drawText("Buffer Target Range", controlX + 3, 12, colors.black, colors.orange)
        
        -- Barre de range
        drawFilledBox({18, 3}, controlX + 3, 13, colors.red, colors.red)
        local rangeWidth = math.floor((config.maxb - config.minb) / 100 * 16)
        local rangeStart = math.floor(config.minb / 100 * 16)
        drawFilledBox({rangeWidth, 3}, controlX + 3 + rangeStart, 13, colors.green, colors.green)
        
        drawText(string.format("%d%%", config.minb), controlX + 2 + rangeStart, 16, colors.black, colors.purple)
        drawText(string.format("%d%%", config.maxb), controlX + 4 + rangeStart + rangeWidth, 16, colors.black, colors.magenta)
        
        -- Boutons de contrôle Min/Max
        drawText("Min", controlX + 8, 18, colors.black, colors.purple)
        drawText("Max", controlX + 20, 18, colors.black, colors.magenta)
        
        -- Boutons Min
        addButton("minMinus10", controlX + 3, 19, 4, 2, minMinus10, colors.purple, colors.white, "- 10")
        addButton("minPlus10", controlX + 8, 19, 4, 2, minPlus10, colors.purple, colors.white, "+ 10")
        
        -- Boutons Max  
        addButton("maxMinus10", controlX + 15, 19, 4, 2, maxMinus10, colors.magenta, colors.white, "- 10")
        addButton("maxPlus10", controlX + 20, 19, 4, 2, maxPlus10, colors.magenta, colors.white, "+ 10")
        
        -- Statistiques
        local statsY = h - 10
        drawBox({controlWidth, h - statsY}, controlX, statsY, colors.blue)
        drawText(" Reactor Statistics ", controlX + 5, statsY, colors.black, colors.blue)
        
        drawText("Generating : " .. format(averageLastRFT) .. "RF/t", 
                controlX + 3, statsY + 2, colors.black, colors.green)
        drawText("RF Drain   : " .. format(averageRfLost) .. "RF/t", 
                controlX + 3, statsY + 4, colors.black, colors.red)
        
        local efficiency = averageFuelUsage > 0 and averageLastRFT / averageFuelUsage or math.huge
        drawText("Efficiency : " .. (efficiency == math.huge and "inf" or format(efficiency)) .. "RF/B",
                controlX + 3, statsY + 6, colors.black, colors.green)
        drawText("Fuel Usage : " .. format(averageFuelUsage) .. "B/t", 
                controlX + 3, statsY + 7, colors.black, colors.green)
        drawText("Waste      : " .. string.format("%d mB", math.floor(averageWaste)),
                controlX + 3, statsY + 8, colors.black, colors.green)
        
        -- Bouton exit
        addButton("exit", w - 6, 1, 6, 1, exitApp, colors.red, colors.white, "EXIT")
    end
    
    -- Dessiner tous les boutons
    for name, _ in pairs(buttons) do
        drawButton(name)
    end
end

-- Gestion des clics (uniquement clic gauche)
local function handleClick(x, y, button)
    if button == 1 then
        return handleButtonClick(x, y)
    end
    return false
end

-- Boucle principale
local function runApp()
    local updateTimer = os.startTimer(0.05)
    
    while running do
        drawInterface()
        
        local event = { os.pullEvent() }
        
        if event[1] == "timer" and event[2] == updateTimer then
            updateStats()
            updateRods()
            updateTimer = os.startTimer(0.05)
            
        elseif event[1] == "mouse_click" then
            handleClick(event[3], event[4], event[2])
            
        elseif event[1] == "key" then
            if event[2] == keys.q then
                running = false
            end
            
        elseif event[1] == "mouse_scroll" then
            local screenType = detectScreenType()
            if screenType == "pocket" then
                local direction = event[2]
                if direction > 0 then
                    scrollOffset = math.min(maxScroll, scrollOffset + 1)
                else
                    scrollOffset = math.max(0, scrollOffset - 1)
                end
            end
            
        elseif event[1] == "terminate" then
            running = false
            
        elseif event[1] == "term_resize" then
            w, h = term.getSize()
        end
    end
end

-- Application principale
local function main()
    if not detectReactor() then
        term.clear()
        term.setCursorPos(1, 1)
        print('Reactor Controller v' .. version)
        print('ERROR: No reactor detected!')
        print('Please connect a reactor peripheral.')
        print('')
        print('Supported reactors:')
        print('- Big Reactors')
        print('- Extreme Reactors') 
        print('- Bigger Reactors')
        print('')
        print('Press any key to exit...')
        os.pullEvent('key')
        return
    end
    
    reactor.setActive(config.reactorActive)
    
    runApp()
    
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Reactor Controller stopped.")
    Config.update(appId, config)
end

if ... then
    return { main = main }
else
    main()
end
