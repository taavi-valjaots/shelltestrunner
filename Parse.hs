module Parse
  ( parseShellTestFile
  )
  where

import Text.Parsec
import Text.Parsec.String

import Import
import Types
import Utils hiding (dbg, ptrace)
import qualified Utils

-- | Parse this shell test file, optionally logging debug output.
parseShellTestFile :: Bool -> FilePath -> IO (Either ParseError [ShellTest])
parseShellTestFile debug f = do
  p <- parseFromFile shelltestfile f
  case p of
    Right ts -> do
           let ts' | length ts > 1 = [t{testname=testname t++":"++show n} | (n,t) <- zip ([1..]::[Int]) ts]
                   | otherwise     = ts
           when (debug) $ do
             printf "parsed %s:\n" f
             mapM_ (putStrLn.(' ':).ppShow) ts'
           return $ Right ts'
    Left _ -> do
           when (debug) $ printf "failed to parse any tests in %s\n" f
           return p


-- parsers

-- show lots of parsing debug output if enabled.
-- NB not connected to the --debug-parse flag
showParserDebugOutput = debugLevel >= 2

ptrace_ s  | showParserDebugOutput = Utils.ptrace s
           | otherwise             = return ()
ptrace s a | showParserDebugOutput = Utils.ptrace $ s ++ ": " ++ show a
           | otherwise             = return ()

shelltestfile :: Parser [ShellTest]
shelltestfile = do
  ptrace_ "shelltestfile 0"
  ts <- try (do first <- try (format2testgroup False)
                rest <- many $ try (format2testgroup True)
                return $ concat $ first : rest
        )
        <|>
        (do first <- try (format2btestgroup False)
            rest <- many $ try (format2btestgroup True)
            return $ concat $ first : rest
        )
        <|>
        (many $ try format1test)
  ptrace_ "shelltestfile 1"
  skipMany whitespaceorcommentline
  ptrace_ "shelltestfile 2"
  eof
  ptrace "shelltestfile ." ts
  return ts


----------------------------------------------------------------------
-- format 1 (shelltestrunner 1.x)
-- each test specifies its input; missing test parts are not checked

format1test = do
  ptrace_ " format1test 0"
  skipMany whitespaceorcommentline
  ptrace_ " format1test 1"
  c <- command1 <?> "command line"
  ptrace " format1test c" c
  i <- optionMaybe input1 <?> "input"
  ptrace " format1test i" i
  o <- optionMaybe expectedoutput1 <?> "expected output"
  ptrace " format1test o" o
  e <- optionMaybe expectederror1 <?> "expected error output"
  ptrace " format1test e" e
  x <- expectedexitcode1 <?> "expected exit status"
  ptrace " format1test x" x
  when (null (show c) && (isNothing i) && (null $ catMaybes [o,e]) && null (show x)) $ fail ""
  f <- sourceName . statePos <$> getParserState
  let t = ShellTest{testname=f,command=c,stdin=i,stdoutExpected=o,stderrExpected=e,exitCodeExpected=x}
  ptrace " format1test ." t
  return t

command1 :: Parser TestCommand
command1 = fixedcommand <|> replaceablecommand

input1 :: Parser String
input1 = try $ string "<<<" >> whitespaceorcommentline >> unlines <$> (line `manyTill` (lookAhead (try delimiter)))

expectedoutput1 :: Parser Matcher
expectedoutput1 = (try $ do
  string ">>>"
  whitespace
  choice [regexmatcher, negativeregexmatcher, whitespaceorcommentlineoreof >> linesmatcher1]
 ) <?> "expected output"

expectederror1 :: Parser Matcher
expectederror1 = (try $ do
  string ">>>2"
  whitespace
  choice [regexmatcher, negativeregexmatcher, (whitespaceorcommentlineoreof >> linesmatcher1)]
 ) <?> "expected error output"

expectedexitcode1 :: Parser Matcher
expectedexitcode1 = (try $ do
  string ">>>="
  whitespace
  fromMaybe anyMatcher <$> (optionMaybe $ choice [regexmatcher, try negativeregexmatcher, numericmatcher, negativenumericmatcher])
 ) <?> "expected exit status"

----------------------------------------------------------------------
-- format 2
-- input first, then tests; missing test parts are implicitly checked

-- A format 2 test group, optionally with the initial <<< delimiter
-- being optional.
format2testgroup :: Bool -> Parser [ShellTest]
format2testgroup inputRequiresDelimiter = do
  ptrace " format2testgroup 0" inputRequiresDelimiter
  skipMany whitespaceorcommentline
  ptrace_ " format2testgroup 1"
  let startdelims | inputRequiresDelimiter = ["<<<"]
                  | otherwise              = ["<<<", ""]
      enddelims = ["$$$","<<<"]
  i <- optionMaybe (linesBetween startdelims enddelims) <?> "input"
  ptrace " format2testgroup i" i
  ts <- many1 $ try (format2test i)
  ptrace " format2testgroup ." ts
  return ts

format2test :: Maybe String -> Parser ShellTest
format2test i = do
  ptrace_ "  format2test 0"
  skipMany whitespaceorcommentline
  ptrace_ "  format2test 1"
  c <- command2 <?> "command line"
  ptrace "  format2test c" c
  nullstdout <- nullLinesMatcher . sourceLine <$> getPosition
  o <- maybe (Just nullstdout) Just <$> optionMaybe expectedoutput2 <?> "expected output"
  ptrace "  format2test o" o
  nullstderr <- nullLinesMatcher . sourceLine <$> getPosition
  e <- maybe (Just $ nullstderr) Just <$> optionMaybe expectederror2 <?> "expected error output"
  ptrace "  format2test e" e
  x <- fromMaybe nullStatusMatcher <$> optionMaybe expectedexitcode2 <?> "expected exit status"
  ptrace "  format2test x" x
  when (null (show c) && (isNothing i) && (null $ catMaybes [o,e]) && null (show x)) $ fail ""
  f <- sourceName . statePos <$> getParserState
  let t = ShellTest{testname=f,command=c,stdin=i,stdoutExpected=o,stderrExpected=e,exitCodeExpected=x}
  ptrace "  format2test ." t
  return t

nullLinesMatcher n = Lines n ""

nullStatusMatcher  = Numeric "0"

anyMatcher = PositiveRegex ""

command2 :: Parser TestCommand
command2 = string "$$$" >> optional (char ' ') >> (fixedcommand <|> replaceablecommand)

-- In format 2, >>> is used only with /REGEX/, also don't consume the
-- whitespace/comments immediately preceding a following test.
expectedoutput2 :: Parser Matcher
expectedoutput2 = (try $ do
  try (string ">>>" >> whitespace >> (regexmatcher <|> negativeregexmatcher))
  <|> (optional (string ">>>" >> whitespaceline) >> linesmatcher2 <?> "expected output")
 )

-- Don't consume the whitespace/comments immediately preceding a
-- following test.
expectederror2 :: Parser Matcher
expectederror2 = (try $ do
  ptrace_ "   expectederror2 0"
  string ">>>2" >> whitespace
  ptrace_ "   expectederror2 1"
  m <- (regexmatcher <|> negativeregexmatcher)
       <|>
       (newline >> linesmatcher2 <?> "expected error output")
  ptrace "   expectederror2 ." m
  return m
 )

expectedexitcode2 :: Parser Matcher
expectedexitcode2 = expectedexitcode1

-- The format 2 lines matcher consumes lines until one of these:
-- 1. another section delimiter in this test (>>>, >>>2, >>>=)
-- 2. the next test's start delimiter (<<<, $$$), or the start of blank/comment lines preceding it
-- 3. end of file, or the start of blank/comment lines preceding it
linesmatcher2 :: Parser Matcher
linesmatcher2 = do
  ptrace_ "    linesmatcher2 0"
  ln <- sourceLine <$> getPosition
  ls <- unlines <$> 
        line `manyTill` lookAhead (choice' [delimiterNotNewTest
                                           ,many whitespaceorcommentline >> delimiterNewTest
                                           ,many whitespaceorcommentline >> eofasstr])
        <?> "lines of output"
  ptrace "    linesmatcher2 ." ls
  return $ Lines ln ls

delimiterNewTest = do
  -- ptrace_ "     delimiterNewTest 0"
  choice [string "$$$", string "<<<"]

delimiterNotNewTest = do
  -- ptrace_ "    delimiterNotNewTest 0"
  choice [try (string ">>>2"), try (string ">>>="), string ">>>"]

----------------------------------------------------------------------
-- format 2b
-- Like format 2 but with short delimiters.
-- XXX duplication
format2btestgroup :: Bool -> Parser [ShellTest]
format2btestgroup inputRequiresDelimiter = do
  ptrace " format2btestgroup 0" inputRequiresDelimiter
  skipMany whitespaceorcommentline
  ptrace_ " format2btestgroup 1"
  let startdelims | inputRequiresDelimiter = ["<"]
                  | otherwise              = ["<", ""]
      enddelims = ["$","<"]
  i <- optionMaybe (linesBetween startdelims enddelims) <?> "input"
  ptrace " format2btestgroup i" i
  ts <- many1 $ try (format2btest i)
  ptrace " format2btestgroup ." ts
  return ts

format2btest :: Maybe String -> Parser ShellTest
format2btest i = do
  ptrace_ "  format2btest 0"
  skipMany whitespaceorcommentline
  ptrace_ "  format2btest 1"
  c <- command2b <?> "command line"
  ptrace "  format2btest c" c
  nullstdout <- nullLinesMatcher . sourceLine <$> getPosition
  o <- maybe (Just nullstdout) Just <$> optionMaybe expectedoutput2b <?> "expected output"
  ptrace "  format2btest o" o
  nullstderr <- nullLinesMatcher . sourceLine <$> getPosition
  e <- maybe (Just $ nullstderr) Just <$> optionMaybe expectederror2b <?> "expected error output"
  ptrace "  format2btest e" e
  x <- fromMaybe nullStatusMatcher <$> optionMaybe expectedexitcode2b <?> "expected exit status"
  ptrace "  format2btest x" x
  when (null (show c) && (isNothing i) && (null $ catMaybes [o,e]) && null (show x)) $ fail ""
  f <- sourceName . statePos <$> getParserState
  let t = ShellTest{testname=f,command=c,stdin=i,stdoutExpected=o,stderrExpected=e,exitCodeExpected=x}
  ptrace "  format2btest ." t
  return t

command2b :: Parser TestCommand
command2b = string "$" >> optional (char ' ') >> (fixedcommand <|> replaceablecommand)

-- In format 2b, >>> is used only with /REGEX/, also don't consume the
-- whitespace/comments immediately preceding a following test.
expectedoutput2b :: Parser Matcher
expectedoutput2b = (try $ do
  try (string ">" >> whitespace >> (regexmatcher <|> negativeregexmatcher))
  <|> (optional (string ">" >> whitespaceline) >> linesmatcher2b <?> "expected output")
 )

-- Don't consume the whitespace/comments immediately preceding a
-- following test.
expectederror2b :: Parser Matcher
expectederror2b = (try $ do
  ptrace_ "   expectederror2b 0"
  string ">2" >> whitespace
  ptrace_ "   expectederror2b 1"
  m <- (regexmatcher <|> negativeregexmatcher)
       <|>
       (newline >> linesmatcher2b <?> "expected error output")
  ptrace "   expectederror2b ." m
  return m
 )

expectedexitcode2b :: Parser Matcher
expectedexitcode2b = (try $ do
  string ">="
  whitespace
  fromMaybe anyMatcher <$> (optionMaybe $ choice [regexmatcher, try negativeregexmatcher, numericmatcher, negativenumericmatcher])
 ) <?> "expected exit status"

-- The format 2b lines matcher consumes lines until one of these:
-- 1. another section delimiter in this test (>, >2, >=)
-- 2. the next test's start delimiter (<, $), or the start of blank/comment lines preceding it
-- 3. end of file, or the start of blank/comment lines preceding it
linesmatcher2b :: Parser Matcher
linesmatcher2b = do
  ptrace_ "    linesmatcher2b 0"
  ln <- sourceLine <$> getPosition
  ls <- unlines <$> 
        line `manyTill` lookAhead (choice' [delimiterNotNewTest2b
                                           ,many whitespaceorcommentline >> delimiterNewTest2b
                                           ,many whitespaceorcommentline >> eofasstr])
        <?> "lines of output"
  ptrace "    linesmatcher2b ." ls
  return $ Lines ln ls

delimiterNewTest2b = do
  -- ptrace_ "     delimiterNewTest 0"
  choice [string "$", string "<"]

delimiterNotNewTest2b = do
  -- ptrace_ "    delimiterNotNewTest 0"
  choice [try (string ">2"), try (string ">="), string ">"]

----------------------------------------------------------------------
-- common

linesBetween :: [String] -> [String] -> Parser String
linesBetween startdelims enddelims = do
  let delimp "" = string ""
      delimp s  = string s <* whitespace <* newline
  Utils.choice' $ map delimp startdelims
  let end = choice $ (map (try . string) enddelims) ++ [eofasstr]
  unlines <$> line `manyTill` lookAhead end

fixedcommand,replaceablecommand :: Parser TestCommand
fixedcommand = many1 whitespacechar >> line >>= return . FixedCommand
replaceablecommand = line >>= return . ReplaceableCommand

regexmatcher :: Parser Matcher
regexmatcher = (do
  char '/'
  r <- (try escapedslash <|> noneOf "/") `manyTill` (char '/')
  whitespaceorcommentlineoreof
  return $ PositiveRegex r) <?> "regex pattern"

escapedslash :: Parser Char
escapedslash = char '\\' >> char '/'

negativeregexmatcher :: Parser Matcher
negativeregexmatcher = (do
  char '!'
  PositiveRegex r <- regexmatcher
  return $ NegativeRegex r) <?> "negative regex pattern"

numericmatcher :: Parser Matcher
numericmatcher = (do
  s <- many1 $ oneOf "0123456789"
  whitespaceorcommentlineoreof
  return $ Numeric s
  ) <?> "number match"

negativenumericmatcher :: Parser Matcher
negativenumericmatcher = (do
  char '!'
  Numeric s <- numericmatcher
  return $ NegativeNumeric s
  ) <?> "negative number match"

linesmatcher1 :: Parser Matcher
linesmatcher1 = do
  ln <- sourceLine <$> getPosition
  (Lines ln . unlines <$>) (line `manyTill` (lookAhead delimiter)) <?> "lines of output"

delimiter = choice [string "$$$", string "<<<", try (string ">>>2"), try (string ">>>="), string ">>>", eofasstr]

-- longdelims = ["<<<", "$$$", ">>>2", ">>>=", ">>>"]
-- shortdelims = ["<", "$", ">2", ">=", ">"]

-- newlineoreof, whitespacechar :: Parser Char
-- line,lineoreof,whitespace,whitespaceline,commentline,whitespaceorcommentline,whitespaceorcommentlineoreof,delimiter,input :: Parser String

-- lineoreof = (anyChar `manyTill` newlineoreof)
-- XXX shouldn't it be:
lineoreof = (noneOf "\n" `manyTill` newlineoreof)
newlineoreof = newline <|> (eof >> return '\n') <?> "newline or end of file"
line = (anyChar `manyTill` newline) <?> "rest of line"
whitespacechar = oneOf " \t"
whitespace = many whitespacechar
whitespaceline = try (newline >> return "") <|> try (whitespacechar >> whitespacechar `manyTill` newlineoreof)
commentline = try (whitespace >> char '#' >> lineoreof) <?> "comments"
whitespaceorcommentline = commentline <|> whitespaceline
whitespaceorcommentlineoreof = choice [eofasstr, commentline, whitespaceline]
eofasstr = eof >> return ""
