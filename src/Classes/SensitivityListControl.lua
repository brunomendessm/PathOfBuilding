-- Path of Building
--
-- Class: Sensitivity List
-- Ranks the stat axes a build scales with, ordered by what one affix of each is worth.
--
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local s_format = string.format

local SensitivityListClass = newClass("SensitivityListControl", "ListControl", function(self, anchor, rect)
	self.ListControl(anchor, rect, 16, "VERTICAL", false)

	self.colList = {
		{ label = "Axis" },
		{ label = "Current", sortable = true },
		{ label = "One affix" },
		{ label = "Gain", sortable = true },
		{ label = "%", sortable = true },
		{ label = "Elast.", sortable = true },
		{ label = "Confidence" },
	}
	self.colLabels = true
	self.label = "Not analysed yet"
	self:UpdateColumns(rect[3])
end)

-- Column widths are a share of the control's own width, which the tab only knows once it
-- has a viewport. Recalculated on resize rather than fixed at construction, since a width
-- captured from the placeholder rect leaves every column a few pixels wide.
local colShares = { 0.20, 0.12, 0.11, 0.19, 0.10, 0.10, 0.18 }

function SensitivityListClass:UpdateColumns(width)
	if width and width > 0 and self.lastColWidth ~= width then
		self.lastColWidth = width
		for index, col in ipairs(self.colList) do
			col.width = width * colShares[index]
		end
	end
end

function SensitivityListClass:SetReport(report)
	self.report = report
	self.list = { }
	if report and not report.error then
		for _, entry in ipairs(report.pool) do
			t_insert(self.list, entry)
		end
		self.label = "Hover an axis for the sweep behind its number"
	end
end

function SensitivityListClass:ReSort(colIndex)
	local key = ({ nil, "current", nil, "affixGain", "affixPct", "elasticity" })[colIndex]
	if not key then
		return
	end
	t_sort(self.list, function(a, b) return (a[key] or -1) > (b[key] or -1) end)
end

---Classifications the tool cannot stand behind are coloured as warnings rather than
---printed alongside trustworthy ones in the same weight. A stepped or irregular axis
---still has a usable per-affix number, but its trend should not be read as one.
local function confidenceText(curve)
	if not curve then
		return "-"
	end
	if curve:find("IRREGULAR") or curve:find("ESCADA") then
		return colorCodes.WARNING .. curve
	end
	return curve
end

function SensitivityListClass:GetRowValue(column, index, entry)
	if column == 1 then
		return entry.label
	elseif column == 2 then
		return s_format("%d", entry.current)
	elseif column == 3 then
		return entry.affixSize and ("+" .. entry.affixSize) or "-"
	elseif column == 4 then
		return entry.affixGain and formatNumSep(s_format("%.0f", entry.affixGain)) or "-"
	elseif column == 5 then
		return entry.affixPct and s_format("%.2f%%", entry.affixPct) or "-"
	elseif column == 6 then
		return s_format("%.2f", entry.elasticity)
	elseif column == 7 then
		return confidenceText(entry.curve)
	end
end

---The raw sample points live here rather than in the table, so the summary stays readable
---while the evidence behind it is still one hover away. This is also what keeps the
---conservative classification honest: a reader who disagrees with it can see why.
function SensitivityListClass:AddValueTooltip(tooltip, index, entry)
	if tooltip:CheckForUpdate(entry, self.report and self.report.baseValue) then
		tooltip:AddLine(16, colorCodes.CUSTOM .. entry.label)
		tooltip:AddSeparator(10)

		if entry.affixName then
			tooltip:AddLine(14, s_format("^7One affix: ^x33FF77+%d ^7(%s)", entry.affixSize, entry.affixName))
			tooltip:AddLine(14, "^7Largest flat roll in the game's explicit mod pool.")
			tooltip:AddSeparator(8)
		end

		tooltip:AddLine(14, s_format("^7Elasticity: ^7%.3f", entry.elasticity))
		tooltip:AddLine(14, "^7Percent of the metric gained per percent more of this stat.")
		tooltip:AddSeparator(8)

		if entry.quantum then
			tooltip:AddLine(14, s_format("^7Sampled every ^7%g ^7(%s)", entry.quantum, entry.quantumWhy or "?"))
			tooltip:AddLine(14, "^7This axis pays out in steps, so samples are aligned to them.")
			tooltip:AddSeparator(8)
		end

		tooltip:AddLine(14, "^7Yield per unit at each sample point:")
		for i, sample in ipairs(entry.samples or { }) do
			tooltip:AddLine(14, s_format("^8  +%-10s ^7%s", s_format("%g", sample.amount), formatNumSep(s_format("%.1f", sample.perUnit))))
		end

		if entry.curve and (entry.curve:find("IRREGULAR") or entry.curve:find("ESCADA")) then
			tooltip:AddSeparator(8)
			tooltip:AddLine(14, colorCodes.WARNING .. "The yield above does not move consistently.")
			tooltip:AddLine(14, colorCodes.WARNING .. "Read the per-affix number, not the trend.")
		end
	end
end
