-- Path of Building
--
-- Module: Calc Sensitivity
-- Prototype: measures which stat axes a build actually scales with, by injecting
-- marginal amounts of each stat and observing the resulting change in a target metric.
--
-- This is a console-only prototype driven by F7 in dev mode; it has no UI yet.
--

local calcs = ...
local ipairs = ipairs
local pairs = pairs
local type = type
local t_insert = table.insert
local t_sort = table.sort
local s_format = string.format
local m_abs = math.abs
local m_floor = math.floor
local m_min = math.min
local m_max = math.max
local m_ceil = math.ceil

-- Sample points, as multiples of the nominal step for each axis. Sweeping instead of
-- taking a single sample is what exposes non-linearity: a build with compounding
-- synergies (attribute stackers, conversion chains) returns more per unit as the
-- investment grows, which a single derivative at the margin would hide.
local sweepPoints = { 0.25, 0.5, 1, 2, 4 }

-- Sample points used when an axis has a known quantum. Every sample is then a whole
-- number of thresholds away from the build's current position, so all of them sit in the
-- same phase and their marginal yields can be compared to each other.
local alignedPoints = { 1, 2, 4, 8, 16 }

-- Pool axes are stats the build holds a quantity of, so a percentage change is
-- meaningful and elasticity is comparable across all of them.
-- affixPattern matches the flat affix that grants the stat, with a single capture for
-- the top of the roll, so the per-affix column can be sourced from the real mod pool.
local poolAxes = {
	{ label = "Strength", stat = "Str", mod = "Str", affixPattern = "^%+%(%d+%-(%d+)%) to Strength$" },
	{ label = "Dexterity", stat = "Dex", mod = "Dex", affixPattern = "^%+%(%d+%-(%d+)%) to Dexterity$" },
	{ label = "Intelligence", stat = "Int", mod = "Int", affixPattern = "^%+%(%d+%-(%d+)%) to Intelligence$" },
	-- relatedStats names stats that this axis moves indirectly. Adding maximum Life raises
	-- Life Reserved, which is what The Ivory Tower's energy shield modifier keys off, so
	-- the axis inherits that modifier's quantisation through the chain.
	{ label = "Life", stat = "Life", mod = "Life", affixPattern = "^%+%(%d+%-(%d+)%) to maximum Life$", relatedStats = { "LifeReserved", "LifeReservedPercent" } },
	{ label = "Energy Shield", stat = "EnergyShield", mod = "EnergyShield", affixPattern = "^%+%(%d+%-(%d+)%) to maximum Energy Shield$" },
	{ label = "Mana", stat = "Mana", mod = "Mana", affixPattern = "^%+%(%d+%-(%d+)%) to maximum Mana$", relatedStats = { "ManaUnreserved", "ManaReserved" } },
	{ label = "Accuracy", stat = "Accuracy", mod = "Accuracy", affixPattern = "^%+%(%d+%-(%d+)%) to Accuracy Rating$" },
	{ label = "Armour", stat = "Armour", mod = "Armour", affixPattern = "^%+%(%d+%-(%d+)%) to Armour$" },
	{ label = "Evasion", stat = "Evasion", mod = "Evasion", affixPattern = "^%+%(%d+%-(%d+)%) to Evasion Rating$" },
}

-- Multiplier axes have no pool to normalise against, so they are reported as the
-- gain from one typical affix worth of investment instead.
local multiplierAxes = {
	{ label = "Increased Attack Speed", mod = "Speed", modType = "INC", step = 10, flags = ModFlag.Attack, unit = "%" },
	{ label = "Increased Cast Speed", mod = "Speed", modType = "INC", step = 10, flags = ModFlag.Cast, unit = "%" },
	{ label = "Increased Crit Chance", mod = "CritChance", modType = "INC", step = 20, unit = "%" },
	{ label = "Crit Multiplier", mod = "CritMultiplier", modType = "BASE", step = 15, unit = "%" },
	{ label = "Increased Damage", mod = "Damage", modType = "INC", step = 20, unit = "%" },
	{ label = "More Damage", mod = "Damage", modType = "MORE", step = 10, unit = "%" },
	{ label = "Increased Elemental Damage", mod = "ElementalDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Physical Damage", mod = "PhysicalDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Lightning Damage", mod = "LightningDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Fire Damage", mod = "FireDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Cold Damage", mod = "ColdDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Chaos Damage", mod = "ChaosDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Life", mod = "Life", modType = "INC", step = 10, unit = "%" },
	{ label = "Increased Energy Shield", mod = "EnergyShield", modType = "INC", step = 10, unit = "%" },
}

---Finds the largest roll of a flat affix matching the given pattern in the explicit mod
---pool. This keeps the per-affix column tied to what the game can actually roll, rather
---than to an assumed affix size that would quietly decide the ranking.
---Only mods with a non-zero spawn weight somewhere are considered, to skip mods that
---exist in the data but cannot appear on an item.
---@param pattern string @Lua pattern with one capture for the top of the roll
---@return number|nil, string|nil @Highest roll found, and the affix name it came from
local function findTopAffix(pattern)
	local best, bestAffix
	for _, modEntry in pairs(data.itemMods.Explicit) do
		local rollable = false
		for _, weight in ipairs(modEntry.weightVal or { }) do
			if weight > 0 then
				rollable = true
				break
			end
		end
		if rollable then
			for _, line in ipairs(modEntry) do
				local roll = tonumber(line:match(pattern) or "")
				if roll and (not best or roll > best) then
					best, bestAffix = roll, modEntry.affix
				end
			end
		end
	end
	return best, bestAffix
end

---Lists modifiers whose value is quantised by integer division (a PerStat tag with a
---divisor above 1). These are the mechanical source of stepped scaling: ModStore floors
---the division, so the modifier only pays out when the underlying stat crosses a multiple
---of the divisor. A marginal sample can land either side of a threshold, which is what
---makes a derivative untrustworthy on these axes.
---
---This only finds quantisation expressed as a modifier. The calculation engine also floors
---in places that never appear in the mod database -- Strength's melee bonus is
---floor(Str/5) in CalcPerform, and Energy Blade floors the weapon damage it derives from
---energy shield in CalcOffence. Those cannot be listed here, and the second kind cannot be
---aligned away at all, since the floor lands on a derived value whose relationship to the
---injected stat is fractional. An axis feeding such a path will stay IRREGULAR no matter
---how the sampling is chosen, and that is the honest answer rather than a shortcoming.
---@param modDB table @Player mod database
---@param output table @Player output, used to locate the next threshold
local function findSteppedMods(modDB, output)
	local found = { }
	for name, modList in pairs(modDB.mods) do
		for _, mod in ipairs(modList) do
			for _, tag in ipairs(mod) do
				if tag.type == "PerStat" and (tag.div or 1) > 1 and type(mod.value) == "number" then
					local stat = tag.stat or (tag.statList and table.concat(tag.statList, "+")) or "?"
					local current = output[stat] or 0
					local steps = m_floor(current / tag.div)
					t_insert(found, {
						name = name,
						value = mod.value,
						div = tag.div,
						stat = stat,
						current = current,
						steps = steps,
						granted = mod.value * steps,
						toNext = (steps + 1) * tag.div - current,
						source = mod.source or "?",
					})
				end
			end
		end
	end
	t_sort(found, function(a, b) return a.granted > b.granted end)
	return found
end

local function gcd(a, b)
	while b ~= 0 do
		a, b = b, a % b
	end
	return a
end

---Computes the sampling quantum for an axis: the smallest increment that advances every
---stepped modifier feeding that axis by a whole number of thresholds. Sampling at
---multiples of it keeps every sample in the same phase, which is what turns a bouncing
---marginal yield into a readable curve.
---@param axis table
---@param stepped table @Output of findSteppedMods
---@param calcFunc function
---@param baseOutput table
---@return number|nil, string|nil @Quantum in the axis's own units, and how it was derived
local function computeQuantum(axis, stepped, calcFunc, baseOutput)
	local quantum, reason

	-- Direct sources key off the axis stat itself, so their divisor is already expressed
	-- in the units being injected and several of them combine as a least common multiple.
	for _, m in ipairs(stepped) do
		if m.stat == axis.stat and m.div > 1 then
			quantum = quantum and (quantum * m.div / gcd(quantum, m.div)) or m.div
			reason = reason and (reason .. "+" .. m.div) or tostring(m.div)
		end
	end

	-- Indirect sources key off a stat this axis only moves through a chain. The transfer
	-- ratio depends on the build (how much life is actually reserved, for instance), so it
	-- is measured with a probe rather than assumed.
	local related = { }
	for _, stat in ipairs(axis.relatedStats or { }) do
		related[stat] = true
	end
	local probed
	for _, m in ipairs(stepped) do
		if related[m.stat] and m.div > 1 then
			if not probed then
				local probeAmount = 100
				local output = calcFunc({ extraMods = { modLib.createMod(axis.mod, "BASE", probeAmount, "Sensitivity") } })
				probed = { output = output, amount = probeAmount }
			end
			local moved = (probed.output[m.stat] or 0) - (baseOutput[m.stat] or 0)
			local ratio = moved / probed.amount
			if ratio > 0 then
				local effective = m.div / ratio
				if not quantum or effective > quantum then
					quantum = effective
					reason = s_format("%g %s / %.3f", m.div, m.stat, ratio)
				end
			end
		end
	end

	if quantum then
		-- Rounded up rather than incremented: a least common multiple is already exact,
		-- and adding to it would put every sample a little further out of phase than the
		-- last, which is the opposite of the point. Only a measured quantum is fractional,
		-- and there ceiling is enough to clear the threshold.
		quantum = m_ceil(quantum)
	end
	return quantum, reason
end

---Classifies how the return on an axis changes as investment grows.
---Compares the marginal yield of the smallest sample against the largest.
local function classifyCurve(samples)
	local first, last = samples[1], samples[#samples]
	if not first or not last then
		return "?"
	end
	if first.perUnit == 0 then
		-- Nothing at the smallest step but something later means the axis pays out in
		-- steps rather than continuously, which usually indicates integer division
		-- somewhere ("per N maximum Life"). A marginal derivative is the wrong tool
		-- for these: the reported gain depends entirely on where the sample lands
		-- relative to the next threshold.
		return last.perUnit ~= 0 and "ESCADA (ver sweep)" or "sem efeito"
	end

	-- A trend is only meaningful when the marginal yield moves consistently in one
	-- direction. Quantised scaling ("+1 Energy Shield per 10 Strength") makes it bounce
	-- instead, and comparing only the endpoints would render that bouncing as a
	-- confident-looking trend. Direction changes alone are not enough to reject a trend,
	-- since the smallest samples carry rounding noise; the spread between the best and
	-- worst yield has to be wide enough to matter as well.
	local rising, falling = false, false
	local lo, hi = first.perUnit, first.perUnit
	for i = 2, #samples do
		local prev, cur = samples[i - 1].perUnit, samples[i].perUnit
		if prev > 0 then
			if cur / prev > 1.02 then
				rising = true
			elseif cur / prev < 0.98 then
				falling = true
			end
		end
		lo, hi = m_min(lo, cur), m_max(hi, cur)
	end
	if rising and falling and lo > 0 and hi / lo > 1.25 then
		return s_format("IRREGULAR (%.2fx)", hi / lo)
	end

	local ratio = last.perUnit / first.perUnit
	if ratio > 1.05 then
		return s_format("acelera (x%.2f)", ratio)
	elseif ratio < 0.95 then
		return s_format("achata  (x%.2f)", ratio)
	end
	return "linear"
end

---Runs one axis through the full sweep.
---@param calcFunc function @Calculator from calcs.getMiscCalculator
---@param baseValue number @Target metric before any injection
---@param amounts number[] @Exact amounts to inject, one per sample point
---@param modFactory function @Given an amount, returns the list of mods to inject
---@param statName string @Output field holding the target metric
local function sweepAxis(calcFunc, baseValue, amounts, modFactory, statName)
	local samples = { }
	for _, amount in ipairs(amounts) do
		local output = calcFunc({ extraMods = modFactory(amount) })
		local newValue = output[statName] or 0
		local delta = newValue - baseValue
		t_insert(samples, {
			amount = amount,
			delta = delta,
			-- Marginal yield per unit injected, which is what makes sample points
			-- of different sizes comparable to each other.
			perUnit = amount ~= 0 and (delta / amount) or 0,
		})
	end
	return samples
end


---Builds the full sensitivity report as data.
---Yields periodically when run inside a coroutine, so a caller driving this from a UI
---can keep drawing; the work is a few hundred full calculation passes and would
---otherwise freeze the interface for seconds.
---@param build table
---@param statName string|nil @Output field to optimise for; defaults to Hit DPS
---@param progressCallback function|nil @Called with a percentage as the sweep advances
---@return table @Report data, or a table carrying only an error field
function calcs.buildSensitivityReport(build, statName, progressCallback)
	statName = statName or "TotalDPS"

	local calcFunc, baseOutput = calcs.getMiscCalculator(build)
	local baseValue = baseOutput[statName] or 0
	if baseValue == 0 then
		return { error = "Base value for " .. statName .. " is zero; nothing to compare against." }
	end

	local report = {
		statName = statName,
		baseValue = baseValue,
		pool = { },
		mult = { },
		stepped = { },
		inert = { },
	}

	-- Progress is counted in calculation passes rather than axes, since an aligned pool
	-- axis costs more than a multiplier one and a flat count would stall visibly.
	local totalPasses = 1 + (#poolAxes * (#sweepPoints + 2)) + (#multiplierAxes * #sweepPoints)
	local donePasses = 0
	local lastYield = GetTime()
	local function progressed(n)
		donePasses = donePasses + (n or 1)
		if coroutine.running() and GetTime() - lastYield > 100 then
			if progressCallback then
				progressCallback(m_floor(donePasses / totalPasses * 100))
			end
			coroutine.yield()
			lastYield = GetTime()
		end
	end

	-- Control pass: injecting nothing must reproduce the base value. If it does not, the
	-- calculator is not rebuilding the character faithfully and every number below would
	-- be measuring that discrepancy rather than the axis under test.
	local controlValue = calcFunc({ extraMods = { } })[statName] or 0
	progressed()
	report.controlValue = controlValue
	report.controlDrift = m_abs(controlValue - baseValue) / baseValue

	local mainEnv = build.calcsTab and build.calcsTab.mainEnv
	local modDB = mainEnv and mainEnv.player and mainEnv.player.modDB
	local stepped = modDB and findSteppedMods(modDB, baseOutput) or { }

	for _, axis in ipairs(poolAxes) do
		local current = baseOutput[axis.stat] or 0
		if current > 0 then
			local quantum, quantumWhy = computeQuantum(axis, stepped, calcFunc, baseOutput)
			progressed()
			local amounts = { }
			for _, point in ipairs(quantum and alignedPoints or sweepPoints) do
				t_insert(amounts, quantum and (quantum * point) or (current * 0.01 * point))
			end

			local samples = sweepAxis(calcFunc, baseValue, amounts, function(amount)
				return { modLib.createMod(axis.mod, "BASE", amount, "Sensitivity") }
			end, statName)
			progressed(#amounts)

			local nominal = samples[3]
			local elasticity = (nominal.delta / baseValue) / (nominal.amount / current)

			local affixSize, affixName = findTopAffix(axis.affixPattern)
			local affixGain, affixPct
			if affixSize then
				local output = calcFunc({ extraMods = { modLib.createMod(axis.mod, "BASE", affixSize, "Sensitivity") } })
				affixGain = (output[statName] or 0) - baseValue
				affixPct = affixGain / baseValue * 100
				progressed()
			end

			local entry = {
				label = axis.label,
				stat = axis.stat,
				current = current,
				delta = nominal.delta,
				perUnit = nominal.perUnit,
				elasticity = elasticity,
				curve = classifyCurve(samples),
				samples = samples,
				affixSize = affixSize,
				affixName = affixName,
				affixGain = affixGain,
				affixPct = affixPct,
				quantum = quantum,
				quantumWhy = quantumWhy,
			}
			if m_abs(elasticity) < 0.0001 then
				t_insert(report.inert, axis.label)
			else
				t_insert(report.pool, entry)
			end
		end
	end

	for _, axis in ipairs(multiplierAxes) do
		local amounts = { }
		for _, point in ipairs(sweepPoints) do
			t_insert(amounts, axis.step * point)
		end
		local samples = sweepAxis(calcFunc, baseValue, amounts, function(amount)
			return { modLib.createMod(axis.mod, axis.modType, amount, "Sensitivity", axis.flags) }
		end, statName)
		progressed(#amounts)

		local nominal = samples[3]
		local entry = {
			label = axis.label,
			step = axis.step,
			unit = axis.unit,
			delta = nominal.delta,
			pct = nominal.delta / baseValue * 100,
			curve = classifyCurve(samples),
			samples = samples,
		}
		if m_abs(entry.pct) < 0.0001 then
			t_insert(report.inert, axis.label)
		else
			t_insert(report.mult, entry)
		end
	end

	t_sort(report.pool, function(a, b) return (a.affixGain or -1) > (b.affixGain or -1) end)
	t_sort(report.mult, function(a, b) return a.pct > b.pct end)

	-- Each threshold is priced using the measured yield of the stat it grants, which turns
	-- "35 more reserved life" into a number comparable with everything else on screen.
	-- Left nil where that stat had no measurable effect, rather than guessed at.
	local yieldByStat = { }
	for _, entry in ipairs(report.pool) do
		yieldByStat[entry.stat] = entry.perUnit
	end
	for _, m in ipairs(stepped) do
		m.worth = yieldByStat[m.name] and (m.value * yieldByStat[m.name]) or nil
	end
	t_sort(stepped, function(a, b) return (a.worth or -1) > (b.worth or -1) end)
	report.stepped = stepped

	if progressCallback then
		progressCallback(100)
	end
	return report
end

---Writes the report to the console and to a text file.
---Kept as a thin consumer of the report data so the dev-mode path stays available
---independently of the tab, and so the two cannot drift apart.
---@param build table
---@param statName string|nil
---@param showSweep boolean|nil @Also dump every sample point behind each classification
function calcs.runSensitivity(build, statName, showSweep)
	local lines = { }
	local function out(fmt, ...)
		local line = select("#", ...) > 0 and s_format(fmt, ...) or fmt
		t_insert(lines, line)
		ConPrintf("%s", line)
	end

	local report = calcs.buildSensitivityReport(build, statName)

	out("=== ANALISE DE SENSIBILIDADE =============================")
	if report.error then
		out("ERRO: %s", report.error)
	else
		out("Metrica alvo : %s", report.statName)
		out("Valor base   : %.1f", report.baseValue)

		if report.controlDrift > 0.001 then
			out("")
			out("AVISO: passe de controle divergiu da base em %.2f%% (%.1f vs %.1f).", report.controlDrift * 100, report.controlValue, report.baseValue)
			out("Os numeros abaixo NAO sao confiaveis - o calculador nao esta reproduzindo a build.")
		end

		out("")
		out("--- EIXOS DE POOL (ordenado por ganho de um afixo real) ---")
		out("%-16s %9s %8s %13s %7s %8s  %s", "Eixo", "Atual", "Afixo", "Ganho/afixo", "%", "Elast.", "Curva")
		for _, r in ipairs(report.pool) do
			if r.affixSize then
				out("%-16s %9.0f %8d %13.1f %6.2f%% %8.3f  %s", r.label, r.current, r.affixSize, r.affixGain, r.affixPct, r.elasticity, r.curve)
			else
				out("%-16s %9.0f %8s %13s %7s %8.3f  %s", r.label, r.current, "n/d", "n/d", "n/d", r.elasticity, r.curve)
			end
		end

		out("")
		out("Afixo = maior roll plano do pool explicito do jogo. Fontes:")
		for _, r in ipairs(report.pool) do
			if r.affixName then
				out("  %-16s +%d (%s)", r.label, r.affixSize, r.affixName)
			end
		end

		local anyAligned = false
		for _, r in ipairs(report.pool) do
			if r.quantum then
				anyAligned = true
			end
		end
		if anyAligned then
			out("")
			out("Eixos amostrados alinhados aos degraus (quantum, origem):")
			for _, r in ipairs(report.pool) do
				if r.quantum then
					out("  %-16s a cada %-7g (%s)", r.label, r.quantum, r.quantumWhy or "?")
				end
			end
		end

		out("")
		out("--- EIXOS MULTIPLICADORES (ganho por afixo tipico) ---")
		out("%-28s %8s %14s %8s  %s", "Eixo", "Passo", "Ganho", "%", "Curva")
		for _, r in ipairs(report.mult) do
			out("%-28s %7d%s %14.1f %7.2f%%  %s", r.label, r.step, r.unit, r.delta, r.pct, r.curve)
		end

		out("")
		out("--- FONTES DE ESCALONAMENTO EM DEGRAU (PerStat com divisao inteira) ---")
		if #report.stepped == 0 then
			out("Nenhuma encontrada.")
		else
			out("%-18s %7s %-18s %9s %7s %9s %9s %12s", "Concede", "Por", "A cada N de", "Atual", "Degraus", "Total", "Falta", "Vale")
			for _, m in ipairs(report.stepped) do
				out("%-18s %7.1f %-18s %9.0f %7d %9.1f %9.1f %12s", m.name, m.value, m.div .. " " .. m.stat, m.current, m.steps, m.granted, m.toNext,
					m.worth and s_format("%.0f", m.worth) or "-")
			end
			out("")
			out("Falta = quanto do stat falta para o proximo degrau.")
			out("Vale = ganho na metrica ao cruzar esse degrau.")
			out("Cobre apenas degraus vindos de modificadores. O motor tambem trunca em")
			out("pontos fixos (bonus de Str = floor(Str/5); dano da Energy Blade truncado a")
			out("partir do ES), que nao aparecem aqui e podem manter um eixo IRREGULAR.")
		end

		if showSweep then
			out("")
			out("--- DETALHE DO SWEEP (ganho por unidade injetada em cada ponto) ---")
			out("%-28s %11s %11s %11s %11s %11s", "Eixo", "ponto 1", "ponto 2", "ponto 3", "ponto 4", "ponto 5")
			local function dumpSamples(results)
				for _, r in ipairs(results) do
					local cells = { }
					for _, s in ipairs(r.samples) do
						t_insert(cells, s_format("%11.1f", s.perUnit))
					end
					out("%-28s %s", r.label, table.concat(cells, " "))
				end
			end
			dumpSamples(report.pool)
			dumpSamples(report.mult)
		else
			out("")
			out("(Shift+F7 para o detalhe do sweep de cada eixo)")
		end

		if #report.inert > 0 then
			out("")
			out("--- SEM EFEITO MENSURAVEL (verificar se se aplica a esta build) ---")
			for _, label in ipairs(report.inert) do
				out("  %s", label)
			end
		end
	end
	out("")
	out("=== FIM ==================================================")

	local path = (main and main.userPath or "") .. "sensitivity_report.txt"
	local file = io.open(path, "w")
	if file then
		file:write(table.concat(lines, "\n"), "\n")
		file:close()
		ConPrintf("Sensitivity: report written to %s", path)
	else
		ConPrintf("Sensitivity: could not write report to %s", path)
	end
end
