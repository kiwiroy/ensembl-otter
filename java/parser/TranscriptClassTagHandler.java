package apollo.dataadapter.otter.parser;
import org.xml.sax.*;
import org.xml.sax.ext.*;
import org.xml.sax.helpers.*;
import org.xml.sax.helpers.DefaultHandler;
import apollo.datamodel.*;

public class TranscriptClassTagHandler extends TagHandler{
  public void handleCharacters(
    OtterContentHandler theContentHandler,
    char[] text,
    int start,
    int length
  ){
    Transcript transcript = (Transcript)theContentHandler.getStackObject();
    String characters = (new StringBuffer()).append(text,start,length).toString();
//    transcript.addProperty(TagHandler.TRANSCRIPT_CLASS, characters);
    transcript.setBioType(characters);
  }//end handleTag

  public String getFullName(){
    return "otter:sequenceset:gene:transcript:transcript_class";
  }//end getFullName
  
  public String getLeafName() {
    return "transcript_class";
  }//end getLeafName
}//end TagHandler
