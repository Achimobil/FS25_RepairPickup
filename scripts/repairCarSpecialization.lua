--[[
RepairCarSpecialization Script File

Copyright (C) Achimobil

Author: Achimobil
Date: 21.11.2024
Version: 0.3.0.0

Project Site:
https://github.com/Achimobil/FS22_RepairPickup

EN Rules:
This script is allowed to copy unchanged in your mod and use it there.
It is not allowed to change the script and republish it in any way. 
There is no additional question needed to use the script, but accept the following:
- You have to keep the script in your mod up to date
- You are responsible for checking regulary for new skript versions in the Repair Pickup publish on forbidden mods or Modhub side
- When there is a script update available you have to use the new script inside of 4 weeks after publish of the new script
- When you have not updated your mod withoun 4 weeks any other modder is allowed to update the script in your mod and republish it without asking you.
You accept these by coping the script in your mod.

DE Regeln:
Dieses Skript darf unverändert in Ihren Mod kopiert und dort verwendet werden.
Es ist nicht erlaubt, das Skript zu ändern und es in irgendeiner Weise neu zu veröffentlichen. 
Für die Verwendung des Skriptes sind keine weiteren Fragen notwendig, jedoch ist folgendes zu beachten:
- Ihr müsst das Skript in eurer Mod auf dem neuesten Stand halten
- Du bist dafür verantwortlich, regelmäßig zu überprüfen, ob neue Skriptversionen im Repair Pickup auf der forbidden Mods Seite oder Modhub veröffentlicht wurden
- Wenn ein Skript-Update verfügbar ist, musst du das neue Skript innerhalb von 4 Wochen nach Veröffentlichung des neuen Skripts verwenden
- Wenn du dein Skript nicht innerhalb von 4 Wochen aktualisiert hast, ist es jedem anderen Modder erlaubt, das Skript in deinem Mod zu aktualisieren und es erneut zu veröffentlichen, ohne dich zu fragen.
Du akzeptierst dies, indem du das Skript in deinen Mod kopierst.

Changelog
0.3.0.0 - Converted to FS25
]]

RepairCarSpecialization = {
	prerequisitesPresent = function()
		return true
	end,
	Version = "0.3.0.0",
	Name = "RepairCarSpecialization",
	Debug = true
}

function RepairCarSpecialization.DebugTable(text, myTable, maxDepth)
	if not RepairCarSpecialization.Debug then return end
	if myTable == nil then
		print("RepairCarSpecializationDebug: " .. text .. " is nil");
	else
		print("RepairCarSpecializationDebug: " .. text)
		DebugUtil.printTableRecursively(myTable,"_",0, maxDepth or 2);
	end
end

-- Beispiel: RepairCarSpecialization.DebugText("Alter: %s", age)
function RepairCarSpecialization.DebugText(text, ...)
	if not RepairCarSpecialization.Debug then return end
	print("RepairCarSpecializationDebug: " .. string.format(text, ...));
end

print(g_currentModName .. " - init " .. RepairCarSpecialization.Name .. "(Version: " .. RepairCarSpecialization.Version .. ")");

function RepairCarSpecialization.initSpecialization()	local schema = Vehicle.xmlSchema
	schema:setXMLSpecializationType("RepairCar")

	local baseXmlPath = "vehicle.repairCar.repairCarConfigurations.repairCarConfiguration(?)"

	schema:register(XMLValueType.NODE_INDEX, baseXmlPath .. ".triggerNodes.triggerNode(?)#node", "Trigger node for repair")
	schema:register(XMLValueType.FLOAT, baseXmlPath .. "#repairPerInterval", "Percentag of repaired damage per interval", 0.2)
	schema:register(XMLValueType.INT, baseXmlPath .. "#repairInterval", "miliseconds between repairs", 5000)
	schema:register(XMLValueType.INT, baseXmlPath .. "#repairCostFactor", "factor for repair costs", 1)
	schema:register(XMLValueType.INT, baseXmlPath .. "#fillUnitIndex", "Fill unit index to consume instead of money. Money used when not set")

	schema:setXMLSpecializationType()
end

function RepairCarSpecialization.registerEventListeners(vehicleType)
	SpecializationUtil.registerEventListener(vehicleType, "onLoad", RepairCarSpecialization);
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", RepairCarSpecialization)
end

function RepairCarSpecialization.registerFunctions(vehicleType)
	SpecializationUtil.registerFunction(vehicleType, "repairTriggerCallback", RepairCarSpecialization.repairTriggerCallback);
	SpecializationUtil.registerFunction(vehicleType, "writeToLog", RepairCarSpecialization.writeToLog);
	SpecializationUtil.registerFunction(vehicleType, "startRepairVehicles", RepairCarSpecialization.startRepairVehicles);
end

function RepairCarSpecialization:onLoad(savegame)
	local repairCarConfigurationId = Utils.getNoNil(self.configurations["repairCar"], 1)
	local baseXmlPath = string.format("vehicle.repairCar.repairCarConfigurations.repairCarConfiguration(%d)", repairCarConfigurationId -1)
	
	-- init for server and client here
	self.spec_repairCar = {};
	local spec = self.spec_repairCar;
	spec.debug = false;
	
	if self.isServer then
		spec.triggerNodes = {};
		spec.vehicleInTrigger = {};
		spec.numVehicleInTrigger = 0;
		
		spec.repairPerInterval = self.xmlFile:getValue(baseXmlPath .. "#repairPerInterval", 0.2);
		spec.repairInterval = self.xmlFile:getValue(baseXmlPath .. "#repairInterval", 5000);
		spec.repairCostFactor = self.xmlFile:getValue(baseXmlPath .. "#repairCostFactor", 1);
		spec.fillUnitIndex = self.xmlFile:getValue(baseXmlPath .. "#fillUnitIndex")
		
		if spec.fillUnitIndex ~= nil then
			-- define the costs to calcualte the amount of filltype used
			spec.fillType = self:getFillUnitFirstSupportedFillType(spec.fillUnitIndex);
			spec.fillTypePricePerLiter = g_currentMission.economyManager:getPricePerLiter(spec.fillType)
		end
		
		self.xmlFile:iterate(baseXmlPath .. ".triggerNodes.triggerNode", 
			function (index, triggerKey)
				local triggerNode = self.xmlFile:getValue(triggerKey .. "#node", nil, self.components, self.i3dMappings);
				table.insert(spec.triggerNodes, triggerNode);
				addTrigger(triggerNode, "repairTriggerCallback", self);
			end
		)
		
		if #spec.triggerNodes == 0 then
			Logging.xmlError(self.xmlFile, "No valid trigger node found");
		end
	end
end

function RepairCarSpecialization:onDelete()
	local spec = self.spec_repairCar;
	if spec ~= nil and spec.triggerNodes ~= nil then
		for _, triggerNode in pairs(spec.triggerNodes) do
			removeTrigger(triggerNode);
		end
	end
end

function RepairCarSpecialization:writeToLog(onlyInDebug, value)
	local spec = self.spec_repairCar;
	
	if (onlyInDebug and spec.debug)then
		print("Debug: " .. tostring(value));
	end
	
	if not onlyInDebug then
		print("Info: " .. tostring(value));
	end
end

function RepairCarSpecialization:repairTriggerCallback(triggerId, otherActorId, onEnter, onLeave, onStay, otherShapeId)
	local spec = self.spec_repairCar;
	self:writeToLog(true, "repairTriggerCallback called");
	self:writeToLog(true, "triggerId:" .. tostring(triggerId) .. " otherActorId:" .. tostring(otherActorId) .. " otherShapeId:" .. tostring(otherShapeId));
	self:writeToLog(true, "onEnter:" .. tostring(onEnter) .. " onLeave:" .. tostring(onLeave) .. " onStay:" .. tostring(onStay));
	
	local vehicle = g_currentMission:getNodeObject(otherActorId);
	if vehicle ~= nil and vehicle.getDamageAmount ~= nil then
		local vehicleRootNode = otherActorId;
		self:writeToLog(true, "vehicle found:" .. tostring(vehicleRootNode));
		if onEnter then
			local foundInTable = false;
			if spec.vehicleInTrigger[vehicleRootNode] ~= nil then
				foundInTable = true;
				spec.vehicleInTrigger[vehicleRootNode] = spec.vehicleInTrigger[vehicleRootNode] + 1;
			end
			
			if not foundInTable then
				spec.vehicleInTrigger[vehicleRootNode] = 1;
				spec.numVehicleInTrigger = spec.numVehicleInTrigger + 1;
				if spec.timerId == nil then
					self:startRepairVehicles();
				end
			end
			self:writeToLog(true, "vehicle counter:" .. tostring(spec.vehicleInTrigger[vehicleRootNode]));
		end
		if onLeave then
			if spec.vehicleInTrigger[vehicleRootNode] ~= nil then
				spec.vehicleInTrigger[vehicleRootNode] = spec.vehicleInTrigger[vehicleRootNode] - 1;
				if spec.vehicleInTrigger[vehicleRootNode] == 0 then
					spec.vehicleInTrigger[vehicleRootNode] = nil;
					spec.numVehicleInTrigger = spec.numVehicleInTrigger - 1;
					self:writeToLog(true, "vehicle removed");
				else
					self:writeToLog(true, "vehicle counter:" .. tostring(spec.vehicleInTrigger[vehicleRootNode]));
				end
			end
		end
	else
		self:writeToLog(true, "Not a vehicle");
	end
end

function RepairCarSpecialization:startRepairVehicles()
	local spec = self.spec_repairCar;
	self:writeToLog(true, "startRepairVehicles called: " .. tostring(spec.numVehicleInTrigger));
	
	if spec.numVehicleInTrigger > 0 then

		local actionDone = false;
		for vehicleRootNode, vehicleCount in pairs(spec.vehicleInTrigger) do
			local vehicle = g_currentMission.nodeToObject[vehicleRootNode];
			
			if vehicle ~= nil and vehicle.getDamageAmount ~= nil then
				self:writeToLog(true, "vehicle: " .. tostring(vehicleRootNode));
				local currentDamage = vehicle:getDamageAmount();
				self:writeToLog(true, "currentDamage: " .. tostring(currentDamage));
				if currentDamage >= 0.0001 then
					-- what will be the price for the repair step
					local repairStep = math.min(currentDamage, spec.repairPerInterval);
					self:writeToLog(true, "repairStep: " .. tostring(repairStep));
					local repairCosts = Wearable.calculateRepairPrice(self:getPrice(), repairStep) * spec.repairCostFactor;
					self:writeToLog(true, "repairCosts: " .. tostring(repairCosts));
					
					if spec.fillUnitIndex ~= nil then
						-- repair with filltype
						self:writeToLog(true, "repair with filltype");
						
						local liter = repairCosts / spec.fillTypePricePerLiter;
						self:writeToLog(true, "needed liter: " .. tostring(liter));
						-- reparieren, wenn es genug ist und abziehen
						if self:getFillUnitFillLevel(spec.fillUnitIndex) >= liter then
							self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, -liter, spec.fillType, ToolType.UNDEFINED, nil);
							vehicle:addDamageAmount(repairStep * -1, true);
							actionDone = true;
						end
					elseif g_currentMission:getMoney(self.ownerFarmId) >= repairCosts then					
						-- repair with money
						self:writeToLog(true, "repair with money")
						g_currentMission:addMoney(-repairCosts, self:getOwnerFarmId(), MoneyType.VEHICLE_REPAIR, true, true);
						vehicle:addDamageAmount(repairStep * -1, true);
						actionDone = true;
					end
				end
			end
		end

		if spec.timerId ~= nil then
			self:writeToLog(true, "timer restarted")
			return true;
		else
			-- set intervall length here in miliseconds
			self:writeToLog(true, "timer added")
			spec.timerId = addTimer(spec.repairInterval, "startRepairVehicles", self);
		end
	else
		-- no vehicle, remove timer
		self:writeToLog(true, "timer removed")
		spec.timerId = nil;
	end
end