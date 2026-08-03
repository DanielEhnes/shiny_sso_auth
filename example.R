ui <- fluidPage(

  theme = bs_theme(version = 5, bootswatch= "flatly"),

 

  ######### HEADER #########

 

  tags$img(src = "ogo.svg", class= "top-logo"),

  #########################

 

  titlePanel("Landing Zone"),

 

  tags$style(HTML("

          .top-logo {

            position: absolute;

            right: 20px;

            top:15px;

            height: 32px;

          }

          .card-deck {

          display: flex;

          justify-content: space-around;

          flex-wrap: wrap;

          }

          .card {

            width: 20rem;

            margin: 1rem 4rem;

            cursor: pointer;

          }

          .icon-white {

           filter: brightness(0) invert(1) saturate(100%)

          }

          .tooltip-inner {

            text-align: left;

            max-width: 400px

          }

      ")

  ),

 

  tags$script(HTML("

      $(function () {

        $('[data-bs-toggle=\"tooltip\"]').tooltip();

      });

    ")),

            

  div(class= "card-deck", style="margin-top: 100px;",

     

      # Tool 1

      tags$div(

        `data-bs-toggle`= "tooltip",

        `data-bs-placement`= "bottom",

        `data-bs-html`= "true",

        title= HTML(" Some TEXT "),

        div(class = "card bg-primary text-white",

            div(class = "card-body",

                div(tags$img(src= "mrel_ICON.png", class="icon-white", height= "60px"),

                    h4(class = "card-title", "Title"), style="display: flex; align-items: center; gap: 10px"

                ),

                p(class = "card-text", "Some text")

            ),

            onclick = "window.open('hyperlink', '_blank')"

        ), div(

          HTML("Ansprechpartner:&nbsp;  <a href='mailto:somebody@somewhere.com'>somebody@somewhere.com</a>"), style =" display: flex; justify-content: center"

        )

      ),
        # Tool 2

      tags$div(

        `data-bs-toggle`= "tooltip",

        `data-bs-placement`= "bottom",

        `data-bs-html`= "true",

        title= HTML(" Some TEXT "),

        div(class = "card bg-primary text-white",

            div(class = "card-body",

                div(tags$img(src= "mrel_ICON.png", class="icon-white", height= "60px"),

                    h4(class = "card-title", "Title"), style="display: flex; align-items: center; gap: 10px"

                ),

                p(class = "card-text", "Some text")

            ),

            onclick = "window.open('hyperlink', '_blank')"

        ), div(

          HTML("Ansprechpartner:&nbsp;  <a href='mailto:somebody@somewhere.com'>somebody@somewhere.com</a>"), style =" display: flex; justify-content: center"

        )

      ),
  )
)