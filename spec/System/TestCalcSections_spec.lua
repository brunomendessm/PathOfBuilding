describe("TestCalcSections", function()
	before_each(function()
		newBuild()
	end)

	local function findSkillTypeStatRow(rowLabel)
		local sectionData = LoadModule("Modules/CalcSections")
		for _, section in ipairs(sectionData) do
			if section[2] == "SkillTypeStats" then
				for _, subSection in ipairs(section[5] or {}) do
					if subSection.label == "Skill type-specific Stats" then
						for _, row in ipairs(subSection.data or {}) do
							if row.label == rowLabel then
								return row
							end
						end
					end
				end
			end
		end
	end

	local function hasModTable(row, expectedLabel, expectedModName)
		for _, entry in ipairs(row or {}) do
			if type(entry) == "table" and entry.label == expectedLabel then
				local modName = entry.modName
				if type(modName) == "string" and modName == expectedModName then
					return true
				end
				if type(modName) == "table" then
					for _, name in ipairs(modName) do
						if name == expectedModName then
							return true
						end
					end
				end
			end
		end
		return false
	end

	local function getModTable(row, expectedLabel)
		for _, entry in ipairs(row or {}) do
			if type(entry) == "table" and entry.label == expectedLabel then
				return entry
			end
		end
	end

	it("shows a cost multiplier modifiers table for Life Cost breakdown", function()
		local lifeCostRow = findSkillTypeStatRow("Life Cost")
		assert.is_not_nil(lifeCostRow)
		assert.True(hasModTable(lifeCostRow, "Cost multiplier modifiers", "SupportManaMultiplier"))
		local multiplierTable = getModTable(lifeCostRow, "Cost multiplier modifiers")
		assert.are.equals("typed", multiplierTable.modValueFormat)
	end)
end)
