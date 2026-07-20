-- Path of Building
--
-- Class: Breakpoint List
-- Modifiers that pay out in steps, and how far the build is from the next one.
--
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local s_format = string.format

local BreakpointListClass = newClass("BreakpointListControl", "ListControl", function(self, anchor, rect)
	self.ListControl(anchor, rect, 16, "VERTICAL", false)

	self.colList = {
		{ label = "Gains" },
		{ label = "Every" },
		{ label = "Have", sortable = true },
		{ label = "To next", sortable = true },
		{ label = "Worth", sortable = true },
	}
	self.colLabels = true
	self.label = "Not analysed yet"
	self:UpdateColumns(rect[3])
end)

-- See SensitivityListControl: widths are a share of the control's runtime width, not of
-- the placeholder rect it was constructed with.
local colShares = { 0.26, 0.26, 0.14, 0.13, 0.21 }

function BreakpointListClass:UpdateColumns(width)
	if width and width > 0 and self.lastColWidth ~= width then
		self.lastColWidth = width
		for index, col in ipairs(self.colList) do
			col.width = width * colShares[index]
		end
	end
end

function BreakpointListClass:SetReport(report)
	self.report = report
	self.list = { }
	if report and not report.error then
		for _, entry in ipairs(report.stepped) do
			t_insert(self.list, entry)
		end
		self.label = #self.list > 0 and "Closing a gap here is the cheapest gain available"
			or "This build has no stepped modifiers"
	end
end

function BreakpointListClass:ReSort(colIndex)
	local key = ({ nil, nil, "current", "toNext", "worth" })[colIndex]
	if not key then
		return
	end
	-- Distance to the next threshold sorts ascending: the nearest one is the useful one.
	local ascending = key == "toNext"
	t_sort(self.list, function(a, b)
		local av, bv = a[key] or -1, b[key] or -1
		if ascending then
			return av < bv
		end
		return av > bv
	end)
end

function BreakpointListClass:GetRowValue(column, index, entry)
	if column == 1 then
		return s_format("+%g %s", entry.value, entry.name)
	elseif column == 2 then
		return s_format("%g %s", entry.div, entry.stat)
	elseif column == 3 then
		return formatNumSep(s_format("%.0f", entry.current))
	elseif column == 4 then
		return s_format("%.0f", entry.toNext)
	elseif column == 5 then
		-- Left blank rather than zeroed where the granted stat had no measurable effect
		-- on the chosen metric, since a zero would read as "worthless" instead of
		-- "not priced".
		return entry.worth and (colorCodes.POSITIVE .. formatNumSep(s_format("%.0f", entry.worth))) or "^8-"
	end
end

function BreakpointListClass:AddValueTooltip(tooltip, index, entry)
	if tooltip:CheckForUpdate(entry, self.report and self.report.baseValue) then
		tooltip:AddLine(16, colorCodes.CUSTOM .. s_format("+%g %s per %g %s", entry.value, entry.name, entry.div, entry.stat))
		tooltip:AddSeparator(10)
		tooltip:AddLine(14, s_format("^7Source: ^8%s", entry.source or "?"))
		tooltip:AddLine(14, s_format("^7Currently at ^7%.0f %s^7, giving ^7%d ^7steps (%g %s total)", entry.current, entry.stat, entry.steps, entry.granted, entry.name))
		tooltip:AddSeparator(8)
		tooltip:AddLine(14, s_format("^7Next step needs ^x33FF77%.0f ^7more %s", entry.toNext, entry.stat))
		if entry.worth then
			tooltip:AddLine(14, s_format("^7Crossing it is worth about ^x33FF77%s ^7of the chosen metric.", formatNumSep(s_format("%.0f", entry.worth))))
		else
			tooltip:AddLine(14, "^8Not priced: the stat it grants had no measurable effect on this metric.")
		end
		tooltip:AddSeparator(8)
		tooltip:AddLine(14, "^8Integer division means this pays nothing until the threshold is crossed.")
	end
end
