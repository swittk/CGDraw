CGDraw = ( options ) ->
	app.userInteractionLevel = UserInteractionLevel.DISPLAYALERTS
	pWin = new Window "palette"
	pWin.text = "A Progress Bar"
	pWin.pBar = pWin.add "progressbar", undefined, 0, 250
	pWin.pBar.preferredSize = [ 250, 10 ]
	doc = app.activeDocument
	org = doc.rulerOrigin
	currLayer = doc.activeLayer
	# Options:
	# 	lang: "obj-c" | "swift"
	# 	wrap: "closure" | "bare"
	# 	os: "iOS" | "mac"
	# 	ctx: arbitrary string
	# 	bnd: arbitrary string

	round2 = ( number ) ->
		Math.round( number*100 )/100

	manageColor = {
		RGBColor: ( color ) ->
			# CGContextSetRGBFillColor
			r = color.red/255
			g = color.green/255
			b = color.blue/255
			{
				type: "RGB"
				value: "#{r}, #{g}, #{b}, "
			}

		GrayColor: ( color ) ->
			# CGContextSetGrayFillColor
			pct = (100 - color.gray)/100
			{
				type: "Gray"
				value: "#{pct}, #{pct}, #{pct}, "
			}

		# The CMYK colors that CG displays do not seem to be quite the same
		# as the ones displayed in Illustrator. I'm not sure if this is due
		# to rounding or monitor calibration or what.
		CMYKColor: ( color ) ->
			# cmyk is 0-100.
			c = color.cyan/100
			m = color.magenta/100
			y = color.yellow/100
			k = color.black/100
			{
				type: "CMYK"
				value: "#{c}, #{m}, #{y}, #{k}, "
			}
		# TODO: support gradients somehow
		# GradientColor: ( color ) ->
		# 	CGContextDrawLinearGradient
		# 	CGContextDrawRadialGradient
	}

	# for CoreGraphics on iOS, the origin is the top-left corner.
	IOS_fixCoords = ( coordArr ) ->
		coordArr[0] = round2 coordArr[0] + org[0]
		coordArr[1] = round2 doc.height - (org[1] + coordArr[1])
		coordArr.join " "

	# for CoreGraphics on mac, the origin is the bottom-left corner.
	Mac_fixCoords = ( coordArr ) ->
		coordArr[0] = round2 coordArr[0] + org[0]
		coordArr[1] = round2 coordArr[1] + org[1]
		coordArr.join ", "

	checkLinear = ( currPoint, prevPoint ) ->
		p1 = (prevPoint.anchor[0] is prevPoint.rightDirection[0] && prevPoint.anchor[1] is prevPoint.rightDirection[1])
		p2 = (currPoint.anchor[0] is currPoint.leftDirection[0] && currPoint.anchor[1] is currPoint.leftDirection[1])
		(p1 && p2)

	CG_linear = ( currPoint ) ->
		"CGContextAddLineToPoint(#{@context}, #{@fixCoords currPoint.anchor})"

	CG_cubic = ( currPoint, prevPoint ) ->
		"CGContextAddCurveToPoint(#{@context}, #{@fixCoords prevPoint.rightDirection}, #{@fixCoords currPoint.leftDirection}, #{@fixCoords currPoint.anchor})"

	class CGDrawing

		result:     []
		lastFill:   undefined
		lastStroke: undefined
		indent:     ""

		constructor: ( options ) ->
			{ ctx: @context, bnd: @bounds } = options

			switch options.type
				when 'CoreGraphics'
					if "swift" is options.lang
						@initClosure = @initClosureSwift
					else
						@initClosure = @initClosureObjC
						@appendLine = ( string ) ->
							@result.push @indent + string + ';'

					if "closure" is options.wrap
						@initClosure( )
						@indent = "\t"
						@merge = ->
							@indent = ""
							@appendLine "}"
							@result.join "\n"

					if "iOS" is options.os
						@fixCoords = IOS_fixCoords
					else
						@fixCoords = Mac_fixCoords

					@linear = CG_linear
					@cubic  = CG_cubic

		blankLine: ( string ) ->
			@result.push ""

		appendLine: ( string ) ->
			@result.push @indent + string

		collectColors: ( path ) ->
			fillColor   = path.fillColor
			strokeColor = path.strokeColor
			if manageColor[fillColor.typename]
				fill = manageColor[fillColor.typename]( fillColor )
				fill.value += path.opacity/100
			else
				fill = { value: false }

			if manageColor[strokeColor.typename]
				stroke = manageColor[strokeColor.typename]( strokeColor )
				stroke.value += path.opacity/100
			else
				stroke = { value: false }

			[fill, stroke]

		start: ( path ) ->
			[@lastFill, @lastStroke] = @collectColors path
			@lastStrokeSize = if path.stroked then path.strokeWidth else 0

			@blankLine( )
			@appendLine "CGContextSet#{@lastFill.type}FillColor(#{@context}, #{@lastFill.value})"
			if path.stroked
				@appendLine "CGContextSet#{@lastStroke.type}StrokeColor(#{@context}, #{@lastStroke.value})"
			@appendLine "CGContextSetLineWidth(#{@context}, #{@lastStrokeSize})"

		initClosureSwift: ->
			@result.push """
				{ #{@context}, #{@bounds} in
				\tlet verticalRatio: CGFloat = #{@bounds}.size.height/#{doc.height}
				\tlet horizontalRatio: CGFloat = #{@bounds}.size.width/#{doc.width}
				\tlet scale: CGFloat = verticalRatio < horizontalRatio ? verticalRatio : horizontalRatio
				\tCGContextTranslateCTM(context, (bounds.size.width-#{doc.width}*scale)*0.5, (bounds.size.height-#{doc.height}*scale)*0.5)
				\tCGContextScaleCTM(#{@context}, scale, scale)
			"""

		initClosureObjC: ->
			@result.push """
				^(CGContextRef #{@context}, CGRect #{@bounds}) {
				\tconst CGFloat verticalRatio   = #{@bounds}.size.height/#{doc.height};
				\tconst CGFloat horizontalRatio = #{@bounds}.size.width/#{doc.width};
				\tconst CGFloat scale = verticalRatio < horizontalRatio ? verticalRatio : horizontalRatio;
				\tCGContextTranslateCTM(context, (bounds.size.width-#{doc.width}*scale)*0.5, (bounds.size.height-#{doc.height}*scale)*0.5);
				\tCGContextScaleCTM(#{@context}, scale, scale);
			"""

		split: ( path ) ->
			[fill, stroke] = @collectColors path
			strokeSize = if path.stroked then path.strokeWidth else 0
			fillChanged = fill.value isnt @lastFill.value
			strokeChanged = stroke.value isnt @lastStroke.value
			strokeSizeChanged = strokeSize isnt @lastStrokeSize

			if fillChanged or strokeChanged or strokeSizeChanged
				@appendLine "CGContextDrawPath(#{@context}, kCGPathFillStroke)"

			# Gracefully screw up unsupported color types?
			# unless fill.value
			# 	@appendLine CGContextSet#{fill.type}FillColor(#{@context}, #{fill.value})

			@blankLine( )
			if fillChanged
				@lastFill = fill
				if fill.value
					@appendLine "CGContextSet#{fill.type}FillColor(#{@context}, #{fill.value})"
			if strokeChanged
				@lastStroke = stroke
				if stroke.value
					@appendLine "CGContextSet#{stroke.type}StrokeColor(#{@context}, #{stroke.value})"
			if strokeSizeChanged
				@lastStrokeSize = strokeSize
				@appendLine "CGContextSetLineWidth(#{@context}, #{strokeSize})"

		appendPath: ( path ) ->
			@split path
			@createPathFromPoints path.pathPoints

		createPathFromPoints: ( points ) ->
			if points.length > 0
				@appendLine "CGContextMoveToPoint(#{@context}, #{@fixCoords points[0].anchor})"

				for j in [1...points.length] by 1
					currPoint = points[j]
					prevPoint = points[j-1]

					if checkLinear currPoint, prevPoint
						@appendLine @linear currPoint
					else
						@appendLine @cubic currPoint, prevPoint

				prevPoint = points[points.length-1]
				currPoint = points[0]

				if checkLinear currPoint, prevPoint
					@appendLine "CGContextClosePath(#{@context})"
				else
					@appendLine @cubic currPoint, prevPoint

		close: ->
			@appendLine "CGContextDrawPath(#{@context}, kCGPathFillStroke)"

		merge: ->
			@result.join "\n"

	recursePageItem = ( pageItem, paths ) ->
		unless pageItem.hidden
			switch pageItem.typename

				when "CompoundPathItem"
					for pathItemNumber in [pageItem.pathItems.length-1..0] by -1
						pathItem = pageItem.pathItems[pathItemNumber]
						recursePageItem pathItem, paths

				when "GroupItem"
					for subPageItemNumber in [pageItem.pageItems.length-1..0] by -1
						subPageItem = pageItem.pageItems[subPageItemNumber]
						recursePageItem subPageItem, paths

				when "PathItem"
					unless pageItem.guides or pageItem.clipping or not (pageItem.stroked or pageItem.filled) or not pageItem.layer.visible
						paths.push pageItem

	paths = []
	for layer in doc.layers by -1
		if layer.visible
			for pageItem in layer.pageItems by -1
				recursePageItem pageItem, paths

	drawing = new CGDrawing options
	drawing.start paths[0]
	for path in paths
		drawing.appendPath path

	drawing.close( )
	return drawing.merge( )